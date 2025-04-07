pub fn build(unlimited_allocator: mem.Allocator, args: cli.Command.Build) !void {
    const start = time.milliTimestamp();

    var site_root_buf: [fs.max_path_bytes]u8 = undefined;
    const site_root = switch (args.site_root) {
        .relative => |rel_path| try fs.cwd().realpath(rel_path, &site_root_buf),
        .absolute => |abs_path| abs_path,
    };

    var db: Database = try .init(unlimited_allocator);
    defer db.deinit();

    try storage.Page.init(&db);
    try storage.Template.init(&db);
    try storage.Component.init(&db);

    try indexSite(unlimited_allocator, site_root, &db);

    var site: Site = try .init(unlimited_allocator, &db, site_root, args.url_prefix);
    defer site.deinit();

    var out_dir = try fs.openDirAbsolute(args.out_dir, .{});
    defer out_dir.close();

    try site.write(.sitemap, out_dir);
    try site.write(.assets, out_dir);
    try site.write(.pages, out_dir);

    log.info("Elapsed: {d}ms", .{time.milliTimestamp() - start});

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}

fn indexSite(allocator: mem.Allocator, site_root: []const u8, db: *Database) !void {
    try indexPages(allocator, site_root, db);
    try indexTemplates(site_root, db);
    try indexComponents(site_root, db);
}

fn indexPages(unlimited_allocator: mem.Allocator, site_root: []const u8, db: *Database) !void {
    var page_count: u32 = 0;

    var page_it = filesystem.walker(site_root, "pages");
    while (page_it.next() catch |err| switch (err) {
        error.CannotOpenDirectory => {
            log.err("Cannot open pages dir at {s}/{s}.", .{ page_it.root, page_it.subpath });
            log.err("Suggestion: Create the directory {s}/{s}.", .{ page_it.root, page_it.subpath });
            return error.CannotOpenPagesDirectory;
        },
        else => return err,
    }) |entry| {
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
            db,
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
    }

    log.debug("Page Count: {d}", .{page_count});
}

fn indexTemplates(site_root: []const u8, db: *Database) !void {
    var template_count: u32 = 0;

    var template_it = filesystem.walker(site_root, "templates");
    while (template_it.next() catch |err| switch (err) {
        error.CannotOpenDirectory => {
            log.err("Cannot open templates dir at {s}/{s}.", .{ template_it.root, template_it.subpath });
            log.err("Suggestion: Create the directory {s}/{s}.", .{ template_it.root, template_it.subpath });
            return error.CannotOpenTemplatesDirectory;
        },
        else => return err,
    }) |entry| {
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
        const filepath = try entry.realpath(&filepath_buf);

        try storage.Template.insert(
            db,
            .{ .filepath = filepath },
        );

        template_count += 1;
    }

    log.debug("Template Count: {d}", .{template_count});
}

fn indexComponents(site_root: []const u8, db: *Database) !void {
    var component_count: u32 = 0;

    var component_it = filesystem.walker(site_root, "components");
    while (component_it.next() catch |err| switch (err) {
        error.CannotOpenDirectory => {
            log.err("Cannot open components dir at {s}/{s}.", .{ component_it.root, component_it.subpath });
            return error.CannotOpenComponentsDirectory;
        },
        else => return err,
    }) |entry| {
        var filepath_buf: [fs.MAX_NAME_BYTES]u8 = undefined;
        const filepath = try entry.realpath(&filepath_buf);

        try storage.Component.insert(
            db,
            .{
                .name = entry.subpath,
                .filepath = filepath,
            },
        );

        component_count += 1;
    }

    log.debug("Component Count: {d}", .{component_count});
}

const std = @import("std");
const mem = std.mem;
const cli = @import("Cli.zig");
const time = std.time;
const Database = @import("Database.zig");
const storage = @import("storage.zig");
const filesystem = @import("source/filesystem.zig");
const log = std.log.scoped(.goku);
const debug = std.debug;
const fs = std.fs;
const page = @import("page.zig");
const heap = std.heap;
const Site = @import("Site.zig");

const size_of_alice_txt = 1189000;
