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
const tracy = @import("tracy");
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

const Site = @This();

// HTML Sitemap looks like this:
// <nav><ul>
// <li><a href="{slug}">{text}</a></li>
// <li><a href="{slug}">{text}</a></li>
// ...
// </ul></nav>
const html_sitemap_preamble =
    \\<nav><ul>
;
const html_sitemap_postamble =
    \\</ul></nav>
;
// I went to a news website's front page and found that the longest
// article title was 128 bytes long. That seems like it could be
// a reasonable limit, but I'd rather just double it out of the gate
// and set the max length to 256.
const sitemap_url_title_len_max = 256;
// It's ridiculous for a URL to exceed this number of bytes
const http_uri_len_max = 2000;
const sitemap_item_surround = "<li><a href=\"\"></a></li>";
const html_sitemap_item_size_max = sitemap_item_surround.len + http_uri_len_max + sitemap_url_title_len_max;

pub fn init(allocator: mem.Allocator, database: *Database, site_root: []const u8, url_prefix: ?[]const u8) Site {
    return .{
        .allocator = allocator,
        .db = database,
        .site_root = site_root,
        .url_prefix = url_prefix,
    };
}

pub fn deinit(self: Site) void {
    _ = self;
}

pub fn writeSitemap(self: Site, out_dir: fs.Dir) !void {
    const zone = tracy.initZone(@src(), .{ .name = "Write sitemap" });
    defer zone.deinit();

    var file = try out_dir.createFile("_sitemap.html", .{});
    defer file.close();

    var file_buf = io.bufferedWriter(file.writer());

    try file_buf.writer().writeAll(html_sitemap_preamble);

    {
        const get_pages =
            \\SELECT slug, title FROM pages;
        ;

        var get_stmt = try self.db.db.prepare(get_pages);
        defer get_stmt.deinit();

        var it = try get_stmt.iterator(
            struct { slug: []const u8, title: []const u8 },
            .{},
        );

        var arena = heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
            var buffer: [html_sitemap_item_size_max]u8 = undefined;
            var fba = heap.FixedBufferAllocator.init(&buffer);
            var buf = std.ArrayList(u8).init(fba.allocator());

            try buf.writer().print(
                \\<li><a href="{s}{s}">{s}</a></li>
            ,
                .{ self.url_prefix orelse "", entry.slug, entry.title },
            );

            try file_buf.writer().writeAll(buf.items);
        }
    }

    try file_buf.writer().writeAll(html_sitemap_postamble);

    try file_buf.flush();
}

pub fn writeAssets(self: Site, out_dir: fs.Dir) !void {
    _ = self;

    {
        var file = try out_dir.createFile("bulma.css", .{});
        defer file.close();
        try file.writer().writeAll(bulma.min.css);
    }

    {
        var file = try out_dir.createFile("htmx.js", .{});
        defer file.close();
        try file.writer().writeAll(htmx.js);
    }
}

pub fn writePages(self: Site, out_dir: fs.Dir) !void {
    // We create an arena allocator for processing the pages. To avoid
    // allocating/freeing memory at the start/end of each page render,
    // we let the memory grow according to the maximum needs of a page
    // and keep it around until we're done rendering.
    var page_buf_allocator = heap.ArenaAllocator.init(self.allocator);
    defer page_buf_allocator.deinit();

    const get_pages =
        \\SELECT slug, filepath FROM pages;
    ;

    var get_stmt = try self.db.db.prepare(get_pages);
    defer get_stmt.deinit();

    var it = try get_stmt.iterator(
        struct { slug: []const u8, filepath: []const u8 },
        .{},
    );

    var arena = heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
        const zone = tracy.initZone(@src(), .{ .name = "Render Page Loop" });
        defer zone.deinit();

        var this_page_allocator = heap.ArenaAllocator.init(page_buf_allocator.allocator());
        defer this_page_allocator.deinit();

        const allocator = this_page_allocator.allocator();

        const in_file = try fs.openFileAbsolute(entry.filepath, .{});
        defer in_file.close();

        const contents = try in_file.readToEndAlloc(allocator, math.maxInt(u32));
        defer allocator.free(contents);

        const result = page.CodeFence.parse(contents) orelse return error.MalformedPageFile;

        const slug = entry.slug;

        var file_name_buffer: [fs.MAX_NAME_BYTES]u8 = undefined;
        var file_name_fba = heap.FixedBufferAllocator.init(&file_name_buffer);
        var file_name_buf = std.ArrayList(u8).init(file_name_fba.allocator());

        debug.assert(slug.len > 0);
        debug.assert(slug[0] == '/');
        if (slug.len > 1) {
            debug.assert(!mem.endsWith(u8, slug, "/"));
            try file_name_buf.appendSlice(slug);
        }
        try file_name_buf.appendSlice("/index.html");

        const file = file: {
            make_parent: {
                if (fs.path.dirname(file_name_buf.items)) |parent| {
                    debug.assert(parent[0] == '/');
                    if (parent.len == 1) break :make_parent;

                    var dir = try out_dir.makeOpenPath(parent[1..], .{});
                    defer dir.close();
                    break :file try dir.createFile(fs.path.basename(file_name_buf.items), .{});
                }
            }

            break :file try out_dir.createFile(fs.path.basename(file_name_buf.items), .{});
        };
        defer file.close();

        var html_buffer = io.bufferedWriter(file.writer());

        const p: page.Page = .{
            .markdown = .{
                .frontmatter = result.within,
                .content = result.after,
            },
        };

        const data = try p.data(allocator);
        defer data.deinit(allocator);

        var tmpl_arena = heap.ArenaAllocator.init(allocator);
        defer tmpl_arena.deinit();

        const template = template: {
            if (data.template) |t| {
                const template_path = try fs.path.join(tmpl_arena.allocator(), &.{ self.site_root, "templates", t });
                defer allocator.free(template_path);

                var template_file = try fs.openFileAbsolute(template_path, .{});
                defer template_file.close();

                const template = try template_file.readToEndAlloc(tmpl_arena.allocator(), math.maxInt(u32));
                break :template template;
            }

            // no template, so use some sort of fallback
            break :template "<!-- Missing template in page frontmatter -->{{& content }}";
        };

        try renderPage(allocator, p, .{
            .bytes = template,
        }, self.db, self.url_prefix, html_buffer.writer());

        try html_buffer.flush();
    }
}

pub const TemplateOption = union(enum) {
    this: void,
    bytes: []const u8,
};
// Write `page` as an html document to the `writer`.
fn renderPage(allocator: mem.Allocator, p: page.Page, tmpl: TemplateOption, db: *Database, url_prefix: ?[]const u8, writer: anytype) !void {
    const meta = try p.data(allocator);
    defer meta.deinit(allocator);

    log.debug("rendering ({s})[{s}]", .{ meta.title.?, meta.slug });

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const content = if (meta.allow_html) content: {
        try mustache.renderStream(
            allocator,
            p.markdown.content,
            .{
                .db = db,
                .data = meta,
                .site_root = url_prefix orelse "",
            },
            buf.writer(),
        );
        break :content buf.items;
    } else p.markdown.content;

    const template = tmpl.bytes;

    var content_buf = std.ArrayList(u8).init(allocator);
    defer content_buf.deinit();

    try markdown.renderStream(content, url_prefix, content_buf.writer());

    try mustache.renderStream(
        allocator,
        template,
        .{
            .db = db,
            .data = meta,
            .content = content_buf.items,
            .site_root = url_prefix orelse "",
        },
        writer,
    );
}
