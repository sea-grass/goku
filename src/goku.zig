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
    try site.write(.component_assets, out_dir);

    log.info("Elapsed: {d}ms", .{time.milliTimestamp() - start});

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}

pub fn preview(unlimited_allocator: mem.Allocator, args: cli.Command.Preview) !void {
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
    try site.write(.component_assets, out_dir);

    const context: PreviewServer.Context = .{ .site = &site, .out_dir = args.out_dir };
    const config: PreviewServer.Config = .{
        .port = 8552,
        .request = .{ .max_form_count = 1 },
    };
    var server: PreviewServer.Server = try .init(
        unlimited_allocator,
        config,
        &context,
    );
    defer server.deinit();

    var router = try server.router(.{});
    router.get("*", PreviewServer.handleGet, .{});
    router.post("*", PreviewServer.handlePost, .{});

    log.info("Listening on http://localhost:8552", .{});
    try server.listen();
}

const PreviewServer = struct {
    pub const Server = httpz.Server(*const Context);
    pub const Context = struct {
        site: *Site,
        out_dir: []const u8,
    };
    pub const Config = httpz.Config;

    pub fn handleGet(context: *const Context, req: *httpz.Request, res: *httpz.Response) !void {
        res.status = 200;

        const query = try req.query();
        log.info("{d}", .{query.len});
        const config: Site.DispatchWants = wants: {
            for (query.keys) |query_key| {
                if (mem.eql(u8, query_key, "editor")) {
                    break :wants .wants_editor;
                } else if (mem.eql(u8, query_key, "raw")) {
                    break :wants .wants_raw;
                }
            }
            break :wants .wants_content;
        };

        var styles_buf = std.ArrayList(u8).init(req.arena);
        defer styles_buf.deinit();

        var scripts_buf = std.ArrayList(u8).init(req.arena);
        defer styles_buf.deinit();

        context.site.dispatch(req.url.path, res.writer(), styles_buf.writer(), scripts_buf.writer(), .{ .wants = config }) catch |err| {
            switch (err) {
                else => {
                    std.log.err("Encountered error when dispatching request: {any}", .{err});
                    res.status = 500;
                    res.body = "Uh oh!";
                    return;
                },
                error.NotFound => {
                    debug.assert(mem.startsWith(u8, req.url.path, "/"));
                    const sub_path = req.url.path[1..];

                    var dir = try fs.openDirAbsolute(context.out_dir, .{});
                    defer dir.close();

                    var file = dir.openFile(sub_path, .{}) catch |err2| {
                        switch (err2) {
                            error.FileNotFound => {
                                res.status = 404;
                                res.body = "Not foond";
                                return;
                            },
                            else => {
                                std.log.err("Encountered error when dispatching request: {any}", .{err2});
                                res.status = 500;
                                res.body = "Uh oh!";
                                return;
                            },
                        }
                    };
                    defer file.close();

                    var buf: [1024]u8 = undefined;
                    const reader = file.reader();
                    const writer = res.writer();
                    while (true) {
                        const read = try reader.read(&buf);
                        if (read == 0) break;
                        _ = try writer.write(buf[0..read]);
                    }

                    res.header("Cache-Control", "max-age=10");
                    log.info("Done serving {s}", .{sub_path});
                },
            }
        };

        if (styles_buf.items.len > 0) {
            var dir = try fs.openDirAbsolute(context.out_dir, .{});
            defer dir.close();

            const component_css_file = try dir.createFile("component.css", .{});
            defer component_css_file.close();

            try component_css_file.writeAll(styles_buf.items);
        }

        if (scripts_buf.items.len > 0) {
            var dir = try fs.openDirAbsolute(context.out_dir, .{});
            defer dir.close();

            const component_js_file = try dir.createFile("component.js", .{});
            defer component_js_file.close();

            try component_js_file.writeAll(scripts_buf.items);
        }
    }

    pub fn handlePost(context: *const Context, req: *httpz.Request, res: *httpz.Response) !void {
        const query = try req.query();
        log.info("{d}", .{query.len});
        const editor = from_editor: {
            for (query.keys) |query_key| {
                if (mem.eql(u8, query_key, "editor")) {
                    break :from_editor true;
                }
            }
            break :from_editor false;
        };

        if (!editor) {
            respond(400, "Bad request hehe", res);
            return;
        }

        const content_type = req.header("content-type") orelse return respond(400, "Bad request", res);
        if (!mem.eql(u8, content_type, "application/x-www-form-urlencoded")) return respond(400, "Bad request", res);

        const source_abs_path = try context.site.getDispatchSourceFile(req.arena, req.url.path) orelse return respond(400, "Bad request", res);

        const content: []const u8 = content: {
            const fd = try req.formData();
            var it = fd.iterator();
            while (it.next()) |entry| {
                if (mem.eql(u8, entry.key, "content")) {
                    break :content entry.value;
                }
            }
            break :content null;
        } orelse return respond(400, "Bad request", res);

        var buf = std.ArrayList(u8).init(req.arena);
        defer buf.deinit();
        for (content) |c| {
            if (c == '\r') {
                continue;
            } else {
                try buf.append(c);
            }
        }
        const @"without \r" = buf.items;

        // Now that I have the updated content, set the file contents.
        // Here be dragons.
        // Suggest guard rails on overwriting files.
        // Yeesh!
        var file = try fs.openFileAbsolute(source_abs_path, .{ .mode = .write_only });
        defer file.close();
        try file.seekTo(0);
        try file.writeAll(@"without \r");

        // Now that I've set the file contents, serve a redirect so the user loads the page.
        redirect(302, try fmt.allocPrint(req.arena, "{s}?editor", .{req.url.path}), res);

        log.info("coontent({s})", .{content});
    }

    fn respond(status_code: u16, body: ?[]const u8, res: *httpz.Response) void {
        res.status = status_code;
        if (body) |b| res.body = b;
    }

    fn redirect(status_code: u16, url: []const u8, res: *httpz.Response) void {
        res.status = status_code;
        res.header("Location", url);
    }
};

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
const httpz = @import("httpz");
const time = std.time;
const Database = @import("Database.zig");
const storage = @import("storage.zig");
const filesystem = @import("source/filesystem.zig");
const log = std.log.scoped(.goku);
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const page = @import("page.zig");
const heap = std.heap;
const Site = @import("Site.zig");

const size_of_alice_txt = 1189000;
