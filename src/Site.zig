const BatchAllocator = @import("BatchAllocator.zig");
const bulma = @import("bulma");
const htmx = @import("htmx");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.site);
const math = std.math;
const mem = std.mem;
const mustache = @import("mustache.zig");
const page = @import("page.zig");
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const Database = @import("Database.zig");
const markdown = @import("markdown.zig");

// TODO remove this property
// Site root is only used for constructing an absolute path to
// a template file. The db should be used for looking up templates
// instead.
site_root: []const u8,
url_prefix: ?[]const u8,
allocator: mem.Allocator,
db: *Database,
component_assets: *ComponentAssets,

pub const ComponentAssets = struct {
    arena: *heap.ArenaAllocator,
    style_map: std.StringArrayHashMapUnmanaged([]const u8),
    script_map: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(allocator: mem.Allocator, db: *Database) !ComponentAssets {
        const arena = try allocator.create(heap.ArenaAllocator);
        arena.* = .init(allocator);
        _ = db;

        return .{
            .arena = arena,
            .style_map = .empty,
            .script_map = .empty,
        };
    }

    pub fn deinit(self: *ComponentAssets) void {
        const allocator = self.arena.*.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    fn getNumComponents(db: *Database) !usize {
        var stmt = try db.db.prepare("SELECT count(*) FROM components;");
        defer stmt.deinit();
    }
};

const Site = @This();

const HtmlSitemap = struct {
    // HTML HtmlSitemap looks like this:
    // <nav><ul>
    // <li><a href="{slug}">{text}</a></li>
    // <li><a href="{slug}">{text}</a></li>
    // ...
    // </ul></nav>
    pub const preamble =
        \\<nav><ul>
    ;
    pub const postamble =
        \\</ul></nav>
    ;

    /// It's ridiculous for a URI to exceed this number of bytes
    pub const http_uri_len_max = 2000;

    /// I went to a news website's front page and found that the longest
    /// article title was 128 bytes long. That seems like it could be
    /// a reasonable limit, but I'd rather just double it out of the gate
    /// and set the max length to 256.
    pub const url_title_len_max = 256;

    pub const item_surround = "<li><a href=\"\"></a></li>";
    pub const item_size_max = item_surround.len + http_uri_len_max + url_title_len_max;

    pub fn write(site: Site, writer: anytype) !void {
        try writer.writeAll(preamble);

        // iterate over pages in site
        {
            var it = try storage.Page.iterate(
                struct { slug: []const u8, title: []const u8 },
                site.allocator,
                site.db,
            );
            defer it.deinit();

            while (try it.next()) |entry| {
                var buffer: [HtmlSitemap.item_size_max]u8 = undefined;
                var fba = heap.FixedBufferAllocator.init(
                    &buffer,
                );
                var buf = std.ArrayList(u8).init(
                    fba.allocator(),
                );

                try buf.writer().print(
                    \\<li><a href="{s}{s}">{s}</a></li>
                ,
                    .{ site.url_prefix orelse "", entry.slug, entry.title },
                );

                try writer.writeAll(buf.items);
            }
        }

        try writer.writeAll(postamble);
    }
};

const fallback_template =
    "<!-- Missing template in page frontmatter -->{{& content }}";

pub fn init(
    allocator: mem.Allocator,
    database: *Database,
    site_root: []const u8,
    url_prefix: ?[]const u8,
) !Site {
    const component_assets = try allocator.create(ComponentAssets);
    errdefer allocator.destroy(component_assets);
    component_assets.* = try .init(allocator, database);
    errdefer component_assets.deinit();

    const site: Site = .{
        .allocator = allocator,
        .db = database,
        .site_root = site_root,
        .url_prefix = url_prefix,
        .component_assets = component_assets,
    };

    try site.validate();

    return site;
}

pub fn deinit(self: Site) void {
    self.component_assets.deinit();
    self.allocator.destroy(self.component_assets);
}

pub fn validate(self: Site) !void {
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

    var get_stmt = try self.db.db.prepare(get_templates.stmt);
    defer get_stmt.deinit();

    var it = try get_stmt.iterator(
        get_templates.type,
        .{},
    );

    var arena = heap.ArenaAllocator.init(self.allocator);
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

        var get_template_stmt = try self.db.db.prepare(get_template.stmt);
        defer get_template_stmt.deinit();

        var buf: [fs.max_path_bytes]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buf);
        const filepath = try fs.path.join(fba.allocator(), &.{
            self.site_root,
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

pub fn write(
    self: Site,
    part: enum { sitemap, assets, pages, component_assets },
    out_dir: fs.Dir,
) !void {
    switch (part) {
        .sitemap => try writeSitemap(self, out_dir),
        .assets => try writeAssets(out_dir),
        .pages => try writePages(self, out_dir),
        .component_assets => try writeComponentAssets(self, out_dir),
    }
}

fn writeSitemap(self: Site, out_dir: fs.Dir) !void {
    var file = try out_dir.createFile("_sitemap.html", .{});
    defer file.close();

    var file_buf = io.bufferedWriter(file.writer());

    try HtmlSitemap.write(self, file_buf.writer());

    try file_buf.flush();
}

fn writeAssets(out_dir: fs.Dir) !void {
    {
        var file = try out_dir.createFile(
            "bulma.css",
            .{},
        );
        defer file.close();
        try file.writer().writeAll(bulma.min.css);
    }

    {
        var file = try out_dir.createFile(
            "htmx.js",
            .{},
        );
        defer file.close();
        try file.writer().writeAll(htmx.js);
    }
}

fn writePages(self: Site, out_dir: fs.Dir) !void {
    var it = try storage.Page.iterate(
        struct { slug: []const u8, filepath: []const u8 },
        self.allocator,
        self.db,
    );
    defer it.deinit();

    var batch_allocator = BatchAllocator.init(self.allocator);
    defer batch_allocator.deinit();

    while (try it.next()) |entry| {
        defer batch_allocator.flush();

        try _render(
            batch_allocator.allocator(),
            self.db,
            self.component_assets,
            self.url_prefix,
            self.site_root,
            entry.filepath,
            entry.slug,
            .wants_content,
            out_dir,
        );
    }
}

fn writeComponentAssets(self: Site, out_dir: fs.Dir) !void {
    {
        var css_file = try out_dir.createFile("component.css", .{});
        defer css_file.close();
        const file_writer = css_file.writer();

        log.info("Write component.css", .{});

        if (self.component_assets.style_map.count() > 0) {
            for (self.component_assets.style_map.values()) |chunk| {
                try file_writer.print("{s}", .{chunk});
            }
        }
    }

    {
        var js_file = try out_dir.createFile("component.js", .{});
        defer js_file.close();
        const file_writer = js_file.writer();

        log.info("Write component.js", .{});

        if (self.component_assets.script_map.count() > 0) {
            for (self.component_assets.script_map.values()) |chunk| {
                try file_writer.print(
                    \\;(function() {{
                    \\  'use strict';
                    \\{[script_body]s}
                    \\}}())
                ,
                    .{ .script_body = chunk },
                );
            }
        }
    }
}

/// Assumes that the provided allocator is an arena.
/// Reads the page and its associated template from the filesystem
/// and writes the rendered page to a file in the out_dir.
///
/// May also write to the `component.css` file if the page wrote
/// to a dedicated styles buffer while rendering.
fn _render(
    ally: mem.Allocator,
    db: *Database,
    component_assets: *ComponentAssets,
    url_prefix: ?[]const u8,
    site_root: []const u8,
    filepath: []const u8,
    slug: []const u8,
    wants: DispatchWants,
    out_dir: fs.Dir,
) !void {
    switch (wants) {
        .wants_raw => unreachable,
        else => {},
    }

    // Read the file contents
    const contents = contents: {
        const in_file = try fs.openFileAbsolute(
            filepath,
            .{},
        );
        defer in_file.close();

        break :contents try in_file.readToEndAlloc(
            ally,
            math.maxInt(u32),
        );
    };

    // Parse the Page metadata
    const result = page.CodeFence.parse(contents) orelse
        return error.MalformedPageFile;

    const p: page.Page = .{
        .markdown = .{
            .frontmatter = result.within,
            .content = result.after,
        },
    };

    const data = try p.data(ally);

    // Create the out file
    const file = file: {
        var filename_buf = std.ArrayList(u8).init(ally);
        defer filename_buf.deinit();

        // TODO the function accepts slug as an argument but we'll also have
        // the slug after parsing the page metadata out. Is it redundant to
        // accept the slug as a function argument?
        debug.assert(slug.len > 0);
        debug.assert(slug[0] == '/');
        if (slug.len > 1) {
            debug.assert(!mem.endsWith(u8, slug, "/"));
            try filename_buf.appendSlice(slug);
        }
        try filename_buf.appendSlice("/index.html");

        make_parent: {
            if (fs.path.dirname(filename_buf.items)) |parent| {
                debug.assert(parent[0] == '/');
                if (parent.len == 1) break :make_parent;

                var dir = try out_dir.makeOpenPath(
                    parent[1..],
                    .{},
                );
                defer dir.close();
                break :file try dir.createFile(
                    fs.path.basename(filename_buf.items),
                    .{},
                );
            }
        }

        break :file try out_dir.createFile(
            fs.path.basename(filename_buf.items),
            .{},
        );
    };
    defer file.close();

    var html_buffer = io.bufferedWriter(file.writer());

    // Load the template from the filesystem
    const template = template: {
        if (data.template) |t| {
            const template_path = try fs.path.join(
                ally,
                &.{ site_root, "templates", t },
            );

            var template_file = try fs.openFileAbsolute(
                template_path,
                .{},
            );
            defer template_file.close();

            const template = try template_file.readToEndAlloc(
                ally,
                math.maxInt(u32),
            );
            break :template template;
        }

        break :template fallback_template;
    };

    try renderPage(
        ally,
        p,
        .{ .bytes = template },
        db,
        component_assets,
        url_prefix,
        wants,
        html_buffer.writer(),
    );

    try html_buffer.flush();
}

// TODO actual needs don't reflect this initial design. Simplify.
pub const TemplateOption = union(enum) {
    this: void,
    bytes: []const u8,
};

pub fn getDispatchSourceFile(site: *Site, arena: mem.Allocator, slug: []const u8) !?[]const u8 {
    var stmt = try site.db.db.prepare(
        \\SELECT filepath FROM pages WHERE slug = ?;
    );
    defer stmt.deinit();

    if (try stmt.oneAlloc(struct { filepath: []const u8 }, arena, .{}, .{ .slug = slug })) |row| {
        return row.filepath;
    }

    return null;
}

const DispatchError = error{ NotFound, DbError, ReadError, RenderError, OOM };
pub const DispatchWants = enum { wants_editor, wants_raw, wants_content };
const DispatchOptions = struct {
    wants: DispatchWants = .wants_content,
};
pub fn dispatch(site: *Site, slug: []const u8, writer: anytype, styles_writer: anytype, scripts_writer: anytype, options: DispatchOptions) DispatchError!void {
    // Clear style and script maps between page navigations
    site.component_assets.script_map.clearRetainingCapacity();
    site.component_assets.style_map.clearRetainingCapacity();

    log.debug("Dispatch request for slug ({s})", .{slug});
    var stmt = site.db.db.prepare(
        \\SELECT filepath, template FROM pages WHERE slug = ?;
        ,
    ) catch return error.DbError;
    defer stmt.deinit();

    if (stmt.oneAlloc(struct { filepath: []const u8, template: []const u8 }, site.allocator, .{}, .{ .slug = slug }) catch return DispatchError.DbError) |row| {
        var arena = heap.ArenaAllocator.init(site.allocator);
        defer arena.deinit();
        const ally = arena.allocator();

        const filepath = row.filepath;
        const site_root = site.site_root;
        const db = site.db;
        const url_prefix = site.url_prefix orelse "";

        // Read the file contents
        const contents = contents: {
            const in_file = fs.openFileAbsolute(
                filepath,
                .{},
            ) catch return DispatchError.ReadError;
            defer in_file.close();

            break :contents in_file.readToEndAlloc(
                ally,
                math.maxInt(u32),
            ) catch return DispatchError.OOM;
        };

        // Parse the Page metadata
        const result = page.CodeFence.parse(contents) orelse
            return error.RenderError;

        const p: page.Page = .{
            .markdown = .{
                .frontmatter = result.within,
                .content = result.after,
            },
        };

        switch (options.wants) {
            .wants_raw => {
                writer.print("---\n{s}\n---\n{s}\n", .{ p.markdown.frontmatter, p.markdown.content }) catch {};
            },
            else => {
                const data = p.data(ally) catch return DispatchError.RenderError;

                var html_buffer = io.bufferedWriter(writer);
                var styles_buffer = io.bufferedWriter(styles_writer);
                var scripts_buffer = io.bufferedWriter(scripts_writer);

                // Load the template from the filesystem
                const template = template: {
                    if (data.template) |t| {
                        const template_path = fs.path.join(
                            ally,
                            &.{ site_root, "templates", t },
                        ) catch return DispatchError.OOM;

                        var template_file = fs.openFileAbsolute(
                            template_path,
                            .{},
                        ) catch return DispatchError.ReadError;
                        defer template_file.close();

                        const template = template_file.readToEndAlloc(
                            ally,
                            math.maxInt(u32),
                        ) catch return DispatchError.OOM;
                        break :template template;
                    }

                    break :template fallback_template;
                };

                renderPage(
                    ally,
                    p,
                    .{ .bytes = template },
                    db,
                    site.component_assets,
                    url_prefix,
                    options.wants,
                    html_buffer.writer(),
                ) catch return DispatchError.RenderError;

                html_buffer.flush() catch {};
                styles_buffer.flush() catch {};
                scripts_buffer.flush() catch {};
            },
        }
    } else {
        return DispatchError.NotFound;
    }
}

/// Write `page` as an html document to the `writer`.
///
/// TODO Assuming that the allocator is an arena.
fn renderPage(
    allocator: mem.Allocator,
    p: page.Page,
    tmpl: TemplateOption,
    db: *Database,
    component_assets: *ComponentAssets,
    url_prefix: ?[]const u8,
    wants: DispatchWants,
    writer: anytype,
) !void {
    const wants2 = e: switch (wants) {
        .wants_raw => unreachable,
        else => |e| break :e e,
    };

    const meta = try p.data(allocator);
    defer meta.deinit(allocator);

    log.info(
        "Render ({s})[{s}]",
        .{ meta.title.?, meta.slug },
    );

    const content = if (meta.allow_html) content: {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try mustache.renderStream(
            allocator,
            p.markdown.content,
            .{
                .db = db,
                .data = meta,
                .site_root = url_prefix orelse "",
                .component_assets = component_assets,
            },
            buf.writer(),
        );
        break :content try buf.toOwnedSlice();
    } else p.markdown.content;

    const template = tmpl.bytes;

    var content_buf = std.ArrayList(u8).init(allocator);
    defer content_buf.deinit();

    try markdown.renderStream(
        content,
        .{ .url_prefix = url_prefix },
        content_buf.writer(),
    );

    switch (wants2) {
        .wants_editor => {
            const editor_inline_script = "<script>" ++ @embedFile("editor_inline_script.js") ++ "</script>";
            try content_buf.appendSlice(editor_inline_script);
            const editor_inline_styles = "<style>" ++ @embedFile("editor_inline_styles.css") ++ "</style>";
            try content_buf.appendSlice(editor_inline_styles);
        },
        .wants_content => {},
        .wants_raw => unreachable,
    }

    try mustache.renderStream(
        allocator,
        template,
        .{
            .db = db,
            .data = meta,
            .content = content_buf.items,
            .site_root = url_prefix orelse "",
            .component_assets = component_assets,
        },
        writer,
    );
}

const @"test" = struct {
    /// Test that the provided content is rendered correctly.
    pub fn content(expected: []const u8, markdown_content: []const u8) !void {
        const page_to_render: page.Page = .{
            .markdown = .{
                .content = markdown_content,

                .frontmatter =
                \\---
                \\slug: /
                \\title: Hello, world!
                \\template: foo.html
                \\---
                ,
            },
        };

        const template = "{{&content}}";

        var db = blk: {
            var db = try Database.init(testing.allocator);

            try storage.Page.init(&db);
            try storage.Template.init(&db);
            break :blk db;
        };

        defer db.deinit();

        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var styles_buf = std.ArrayList(u8).init(testing.allocator);
        defer styles_buf.deinit();
        var scripts_buf = std.ArrayList(u8).init(testing.allocator);
        defer scripts_buf.deinit();

        try renderPage(
            testing.allocator,
            page_to_render,
            .{ .bytes = template },
            &db,
            null,
            .wants_content,
            buf.writer(),
            styles_buf.writer(),
            scripts_buf.writer(),
        );

        try testing.expectEqualStrings(expected, buf.items);
    }
};

test renderPage {
    try @"test".content(
        "<p>\nHello, world!</p>",
        \\Hello, world!
        ,
    );
}
