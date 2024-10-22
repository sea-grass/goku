const clap = @import("clap");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.goku);
const mem = std.mem;
const page = @import("page.zig");
const process = std.process;
const filesystem = @import("source/filesystem.zig");
const std = @import("std");
const time = std.time;
const tracy = @import("tracy");
const Database = @import("Database.zig");
const Site = @import("Site.zig");

pub const std_options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
};

const size_of_alice_txt = 1189000;

const BuildCommand = struct {
    site_root: []const u8,
    out_dir: []const u8,
    url_prefix: ?[]const u8,

    arena: heap.ArenaAllocator,

    const params = clap.parseParamsComptime(
        \\-h, --help    Display this help text and exit.
        \\<str>         The absolute or relative path to your site's source directory.
        \\-o, --out <str>      The directory to place the generated site.
        \\-p, --prefix <str>    The URL prefix to use when the site root will be published to a subpath. Default: none
        ,
    );

    pub const ParseError = error{
        Help,
        MemoryError,
        MissingOutDir,
        MissingSiteRoot,
        ParseError,
        SiteRootDoesNotExist,
        TooManyParameters,
    };
    pub fn parse(allocator: mem.Allocator) ParseError!BuildCommand {
        var arena = heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var diag: clap.Diagnostic = .{};
        var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
            .diagnostic = &diag,
            .allocator = allocator,
        }) catch |err| {
            // Report useful error on exit
            diag.report(io.getStdErr().writer(), err) catch {};
            return error.ParseError;
        };
        defer res.deinit();

        if (res.args.help != 0) {
            return error.Help;
        }

        var site_root_buf: [fs.max_path_bytes]u8 = undefined;
        const site_root = absolutePath(
            site_root: {
                break :site_root if (res.positionals.len == 1) res.positionals[0] else {
                    if (res.positionals.len < 1) {
                        return error.MissingSiteRoot;
                    }

                    return error.TooManyParameters;
                };
            },
            &site_root_buf,
            .{},
        ) catch return error.SiteRootDoesNotExist;

        var out_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const out_dir_path = absolutePath(
            if (res.args.out) |out| out else {
                return error.MissingOutDir;
            },
            &out_dir_buf,
            .{ .make = true },
        ) catch return error.ParseError;

        const url_prefix: ?[]const u8 = if (res.args.prefix) |prefix| prefix else null;

        return .{
            .site_root = arena.allocator().dupe(u8, site_root) catch return error.MemoryError,
            .out_dir = arena.allocator().dupe(u8, out_dir_path) catch return error.MemoryError,
            .url_prefix = if (url_prefix == null) null else arena.allocator().dupe(u8, url_prefix.?) catch return error.MemoryError,
            .arena = arena,
        };
    }

    pub fn deinit(self: BuildCommand) void {
        self.arena.deinit();
    }

    const AbsolutePathOptions = struct {
        // Make the directory if it does not exist
        make: bool = false,
    };
    fn absolutePath(path: []const u8, buf: []u8, options: AbsolutePathOptions) ![]const u8 {
        if (fs.path.isAbsolute(path)) {
            if (options.make) {
                fs.makeDirAbsolute(path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            }

            return path;
        }

        const cwd = fs.cwd();

        if (options.make) {
            try cwd.makePath(path);
        }

        return try cwd.realpath(path, buf);
    }

    pub fn printHelp() void {
        const stderr = io.getStdErr().writer();

        stderr.print(
            \\Goku - A static site generator
            \\----
            \\Usage:
            \\    goku -h
            \\    goku <site_root> -o <out_dir>
            \\
        ,
            .{},
        ) catch @panic("Could not print help to stderr");

        clap.help(stderr, clap.Help, &params, .{}) catch @panic("Could not print help to stderr");
    }
};

pub fn main() !void {
    const start = time.milliTimestamp();
    log.info("mode {s}", .{@tagName(@import("builtin").mode)});

    tracy.startupProfiler();
    defer tracy.shutdownProfiler();

    tracy.setThreadName("main");
    defer tracy.message("Graceful main thread exit");

    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .leak => {
            log.err("Memory leak...", .{});
        },
        else => {},
    };

    var tracy_allocator = tracy.TracingAllocator.init(gpa.allocator());
    const unlimited_allocator = tracy_allocator.allocator();

    //
    // PARSE CLI ARGUMENTS
    //

    const build = BuildCommand.parse(unlimited_allocator) catch |err| switch (err) {
        BuildCommand.ParseError.Help => {
            BuildCommand.printHelp();
            process.exit(0);
        },
        BuildCommand.ParseError.MissingOutDir,
        BuildCommand.ParseError.MissingSiteRoot,
        BuildCommand.ParseError.TooManyParameters,
        => {
            BuildCommand.printHelp();
            process.exit(1);
        },
        BuildCommand.ParseError.SiteRootDoesNotExist => {
            log.err("Provided site root directory does not exist. Exiting.", .{});
            process.exit(1);
        },
        else => process.exit(1),
    };
    defer build.deinit();

    log.info("Goku Build", .{});
    log.info("Site Root: {s}", .{build.site_root});
    log.info("Out Dir: {s}", .{build.out_dir});

    var db = try Database.init(unlimited_allocator);
    defer db.deinit();

    try Database.Page.init(&db);
    try Database.Template.init(&db);

    //
    // INDEX SITE
    //

    var page_count: u32 = 0;

    {
        var page_it = filesystem.walker(build.site_root, "pages");
        while (try page_it.next()) |entry| {
            const zone = tracy.initZone(@src(), .{ .name = "Load Page from File" });
            defer zone.deinit();

            const file = try entry.openFile();
            defer file.close();

            debug.assert(try file.getPos() == 0);
            const length = try file.getEndPos();

            // alice.txt is 148.57kb. I doubt I'll write a single markdown file
            // longer than the entire Alice's Adventures in Wonderland.
            debug.assert(length < size_of_alice_txt);

            var filepath_buf: [fs.MAX_NAME_BYTES]u8 = undefined;
            const filepath = try entry.realpath(&filepath_buf);

            const data = page.Data.fromReader(unlimited_allocator, file.reader(), size_of_alice_txt) catch |err| {
                switch (err) {
                    error.MissingFrontmatter => {
                        log.err("Malformed page in source file: {s}", .{filepath});
                    },
                    else => {},
                }

                return err;
            };
            defer data.deinit(unlimited_allocator);

            try Database.Page.insert(
                &db,
                .{
                    .slug = data.slug,
                    .title = data.title orelse "(missing title)",
                    .filepath = filepath,
                    .collection = data.collection orelse "",
                    .date = data.date,
                },
            );

            page_count += 1;
            tracy.plot(u32, "Discovered Page Count", page_count);
        }
    }

    var template_count: u32 = 0;

    {
        var template_it = filesystem.walker(build.site_root, "templates");
        while (try template_it.next()) |entry| {
            const zone = tracy.initZone(@src(), .{ .name = "Scan for template files" });
            defer zone.deinit();

            const file = try entry.openFile();
            defer file.close();

            debug.assert(try file.getPos() == 0);
            const length = try file.getEndPos();

            // I don't think it makes sense to have an empty template file, right?
            debug.assert(length > 0);

            var filepath_buf: [fs.MAX_NAME_BYTES]u8 = undefined;

            try Database.Template.insert(
                &db,
                .{
                    .filepath = try entry.realpath(&filepath_buf),
                },
            );

            template_count += 1;
            tracy.plot(u32, "Discovered Template Count", template_count);
        }

        log.debug("Discovered template count {d}", .{template_count});
    }

    //
    // BUILD SITE
    //

    {
        const write_output_zone = tracy.initZone(@src(), .{ .name = "Write Site to Output Dir" });
        defer write_output_zone.deinit();

        var out_dir = try fs.openDirAbsolute(build.out_dir, .{});
        defer out_dir.close();

        var site = Site.init(unlimited_allocator, &db, build.site_root, build.url_prefix);
        defer site.deinit();

        try site.write(.sitemap, out_dir);
        try site.write(.assets, out_dir);
        try site.write(.pages, out_dir);
    }

    log.info("Elapsed: {d}ms", .{time.milliTimestamp() - start});

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}
