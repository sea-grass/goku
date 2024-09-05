const bulma = @import("bulma");
const clap = @import("clap");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.goku);
const math = std.math;
const mem = std.mem;
const page = @import("page.zig");
const process = std.process;
const source = @import("source.zig");
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

    arena: heap.ArenaAllocator,

    const params = clap.parseParamsComptime(
        \\-h, --help    Display this help text and exit.
        \\<str>         The absolute or relative path to your site's source directory.
        \\-o, --out <str>      The directory to place the generated site.
        ,
    );

    pub fn parse(allocator: mem.Allocator) !BuildCommand {
        var arena = heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var diag: clap.Diagnostic = .{};
        var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
            .diagnostic = &diag,
            .allocator = allocator,
        }) catch |err| {
            // Report useful error on exit
            diag.report(io.getStdErr().writer(), err) catch {};
            return err;
        };
        defer res.deinit();

        if (res.args.help != 0) {
            try printHelp();
            process.exit(0);
        }

        var site_root_buf: [fs.max_path_bytes]u8 = undefined;
        const site_root = try absolutePath(
            site_root: {
                break :site_root if (res.positionals.len == 1) res.positionals[0] else {
                    if (res.positionals.len < 1) {
                        log.err("Fatal error: Missing required <site_root> argument.", .{});
                        process.exit(1);
                    }

                    try printHelp();
                    process.exit(1);
                };
            },
            &site_root_buf,
            .{},
        );

        var out_dir_buf: [fs.max_path_bytes]u8 = undefined;
        const out_dir_path = try absolutePath(
            if (res.args.out) |out| out else {
                try printHelp();
                process.exit(1);
            },
            &out_dir_buf,
            .{ .make = true },
        );

        return .{
            .site_root = try arena.allocator().dupe(u8, site_root),
            .out_dir = try arena.allocator().dupe(u8, out_dir_path),
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
                try fs.makeDirAbsolute(path);
            }

            return path;
        }

        const cwd = fs.cwd();

        if (options.make) {
            try cwd.makePath(path);
        }

        return try cwd.realpath(path, buf);
    }

    fn printHelp() !void {
        const stderr = io.getStdErr().writer();
        try stderr.print(
            \\Goku - A static site generator
            \\----
            \\Usage:
            \\    goku -h
            \\    goku <site_root> -o <out_dir>
            \\
        ,
            .{},
        );
        try clap.help(stderr, clap.Help, &params, .{});
    }
};

pub fn main() !void {
    const start = time.milliTimestamp();
    defer log.info("Elapsed: {d}ms", .{time.milliTimestamp() - start});

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

    const build = try BuildCommand.parse(unlimited_allocator);
    defer build.deinit();

    log.info("Goku Build", .{});
    log.info("Site Root: {s}", .{build.site_root});
    log.info("Out Dir: {s}", .{build.out_dir});

    var db = try Database.init(unlimited_allocator);
    defer db.deinit();

    //
    // INDEX SITE
    //

    var page_count: u32 = 0;

    {
        var page_it: source.Filesystem = .{
            .root = build.site_root,
            .subpath = "pages",
        };
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

            const data = try page.Data.fromReader(unlimited_allocator, file.reader(), size_of_alice_txt);
            defer data.deinit(unlimited_allocator);

            var filepath_buf: [fs.MAX_NAME_BYTES]u8 = undefined;
            const filepath = try entry.realpath(&filepath_buf);

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
        var template_it: source.Filesystem = .{
            .root = build.site_root,
            .subpath = "templates",
        };
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

        // TODO restore skip-to-main-content

        var site = Site.init(unlimited_allocator, &db, build.site_root);
        defer site.deinit();

        try site.writeSitemap(out_dir);
        try site.writeAssets(out_dir);
        try site.writePages(out_dir);
    }

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}

test {
    _ = @import("page.zig");
    _ = @import("source.zig");
}
