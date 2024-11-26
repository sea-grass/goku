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
const scaffold = @import("scaffold.zig");
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const time = std.time;
const tracy = @import("tracy");
const Database = @import("Database.zig");
const Site = @import("Site.zig");

pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
};

const size_of_alice_txt = 1189000;

const standard_help =
    \\Goku - A static site generator
    \\----
    \\Usage:
    \\    goku -h
    \\    goku init [<site_root>]
    \\    goku build <site_root> -o <out_dir> [-p <url_prefix>]
    \\
;

const SubCommand = enum {
    build,
    help,
    init,

    const main_parsers = .{
        .command = clap.parsers.enumeration(SubCommand),
    };

    const main_params = clap.parseParamsComptime(
        \\-h, --help  Display this help text and exit.
        \\<command> The subcommand - can be one of build, help, init
        \\
    );

    const MainArgs = clap.ResultEx(clap.Help, &main_params, main_parsers);

    pub fn parse(allocator: mem.Allocator, iter: *process.ArgIterator) !SubCommand {
        var diag: clap.Diagnostic = .{};
        var res = clap.parseEx(clap.Help, &main_params, main_parsers, iter, .{
            .diagnostic = &diag,
            .allocator = allocator,

            // Terminate the parsing of arguments after the first positional,
            // the subcommand. This will leave the rest of the iter args unconsumed,
            // so the iter can be reused for parsing the subcommand arguments.
            .terminating_positional = 0,
        }) catch |err| {
            diag.report(io.getStdErr().writer(), err) catch {};
            return err;
        };
        defer res.deinit();

        if (res.args.help != 0) {
            printHelp();
            process.exit(0);
        }

        return res.positionals[0] orelse return error.MissingCommand;
    }

    pub fn printHelp() void {
        const stderr = io.getStdErr().writer();

        stderr.print(
            "{s}",
            .{standard_help},
        ) catch {};

        clap.help(stderr, clap.Help, &main_params, .{}) catch {};
    }
};

pub fn main() !void {
    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    tracy.startupProfiler();
    defer tracy.shutdownProfiler();

    tracy.setThreadName("main");
    defer tracy.message("Graceful main thread exit");

    var tracy_allocator = tracy.TracingAllocator.init(gpa.allocator());

    const unlimited_allocator = tracy_allocator.allocator();

    var iter = try process.ArgIterator.initWithAllocator(unlimited_allocator);
    defer iter.deinit();

    // skip exe name
    _ = iter.next();

    const command = SubCommand.parse(unlimited_allocator, &iter) catch |err| switch (err) {
        error.MissingCommand => {
            SubCommand.printHelp();
            process.exit(1);
        },
        else => return err,
    };

    switch (command) {
        .help => {
            SubCommand.printHelp();
            process.exit(0);
        },
        .init => {
            try initMain(unlimited_allocator, &iter);
        },
        .build => {
            try buildMain(unlimited_allocator, &iter);
        },
    }
}

pub fn initMain(unlimited_allocator: mem.Allocator, iter: *process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help text and exit.
        \\<str>  The directory to initialize (defaults to the current working directory).
    );

    var diag: clap.Diagnostic = .{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = unlimited_allocator,
    }) catch |err| {
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    const site_root = res.positionals[0] orelse ".";

    if (res.args.help != 0) {
        log.info("THelp", .{});
        process.exit(0);
    }

    log.info("init ({s})", .{site_root});

    var dir = try fs.cwd().makeOpenPath(site_root, .{});
    defer dir.close();

    try scaffold.check(&dir);
    try scaffold.write(&dir);

    log.info("Site scaffolded at ({s}).", .{site_root});
}

pub fn buildMain(unlimited_allocator: mem.Allocator, iter: *process.ArgIterator) !void {
    const start = time.milliTimestamp();
    log.info("mode {s}", .{@tagName(@import("builtin").mode)});

    //
    // PARSE CLI ARGUMENTS
    //

    const build = BuildCommand.parse(unlimited_allocator, iter) catch |err| switch (err) {
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
        BuildCommand.ParseError.MalformedUrlPrefix => {
            log.err("Provided url prefix is invalid. Note that the url prefix must begin with a '/' character.", .{});
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

    try storage.Page.init(&db);
    try storage.Template.init(&db);

    //
    // INDEX SITE
    //

    var page_count: u32 = 0;

    {
        var page_it = filesystem.walker(build.site_root, "pages");
        while (page_it.next() catch |err| switch (err) {
            error.CannotOpenDirectory => {
                log.err("Cannot open pages dir at {s}/{s}.", .{ page_it.root, page_it.subpath });
                log.err("Suggestion: Create the directory {s}/{s}.", .{ page_it.root, page_it.subpath });
                return error.CannotOpenPagesDirectory;
            },
            else => return err,
        }) |entry| {
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
                    error.MissingSlug => {
                        log.err("Page is missing required, non-empty frontmatter parameter: slug (source file: {s})", .{filepath});
                    },
                    error.MissingTitle => {
                        log.err("Page is missing required, non-empty frontmatter parameter: title (source file: {s})", .{filepath});
                    },
                    error.MissingTemplate => {
                        log.err("Page is missing required, non-empty frontmatter parameter: template (source file: {s})", .{filepath});
                    },
                    else => {},
                }

                return err;
            };
            defer data.deinit(unlimited_allocator);

            try storage.Page.insert(
                &db,
                .{
                    .slug = data.slug,
                    .title = data.title orelse "(missing title)",
                    .filepath = filepath,
                    .template = data.template.?,
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
        while (template_it.next() catch |err| switch (err) {
            error.CannotOpenDirectory => {
                log.err("Cannot open templates dir at {s}/{s}.", .{ template_it.root, template_it.subpath });
                log.err("Suggestion: Create the directory {s}/{s}.", .{ template_it.root, template_it.subpath });
                return error.CannotOpenTemplatesDirectory;
            },
            else => return err,
        }) |entry| {
            const zone = tracy.initZone(@src(), .{ .name = "Scan for template files" });
            defer zone.deinit();

            const file = try entry.openFile();
            defer file.close();

            debug.assert(try file.getPos() == 0);
            const length = try file.getEndPos();

            // I don't think it makes sense to have an empty template file, right?
            if (length == 0) {
                log.err("Template file cannot be empty. (template path: {s})", .{entry.subpath});
                return error.EmptyTemplate;
            }

            var filepath_buf: [fs.MAX_NAME_BYTES]u8 = undefined;

            try storage.Template.insert(
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

    {
        // Find all unique templates in pages
        // Ensure each template exists as an entry in sqlite

        const get_templates = .{
            .stmt =
            \\ SELECT DISTINCT template
            \\ FROM pages
            ,
            .type = struct {
                template: []const u8,
            },
        };

        var get_stmt = try db.db.prepare(get_templates.stmt);
        defer get_stmt.deinit();

        var it = try get_stmt.iterator(
            get_templates.type,
            .{},
        );

        var arena = heap.ArenaAllocator.init(unlimited_allocator);
        defer arena.deinit();

        while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
            const get_template = .{
                .stmt =
                \\ SELECT filepath
                \\ FROM templates
                \\ WHERE filepath = ?
                \\ LIMIT 1
                ,
                .type = struct {
                    filepath: []const u8,
                },
            };

            var get_template_stmt = try db.db.prepare(get_template.stmt);
            defer get_template_stmt.deinit();

            var buf: [fs.max_path_bytes]u8 = undefined;
            var fba = heap.FixedBufferAllocator.init(&buf);
            const filepath = try fs.path.join(fba.allocator(), &.{
                build.site_root,
                "templates",
                entry.template,
            });

            const row = try get_template_stmt.oneAlloc(
                get_template.type,
                arena.allocator(),
                .{},
                .{
                    .filepath = filepath,
                },
            );

            if (row == null) {
                log.err("The template ({s}) does not exist.", .{entry.template});
                return error.MissingTemplate;
            }
        }
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
        MalformedUrlPrefix,
        MemoryError,
        MissingOutDir,
        MissingSiteRoot,
        ParseError,
        SiteRootDoesNotExist,
        TooManyParameters,
    };
    pub fn parse(allocator: mem.Allocator, iter: *process.ArgIterator) ParseError!BuildCommand {
        var arena = heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var diag: clap.Diagnostic = .{};
        var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
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
                break :site_root if (res.positionals.len == 1)
                    res.positionals[0] orelse return error.MissingSiteRoot
                else {
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

        if (url_prefix != null) {
            if (!mem.startsWith(u8, url_prefix.?, "/")) {
                return error.MalformedUrlPrefix;
            }
        }

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
            "{s}",
            .{standard_help},
        ) catch {};

        clap.help(stderr, clap.Help, &params, .{}) catch {};
    }
};
