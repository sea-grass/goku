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
) Site {
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

pub fn write(
    self: Site,
    part: enum { sitemap, assets, pages },
    out_dir: fs.Dir,
) !void {
    switch (part) {
        .sitemap => try writeSitemap(self, out_dir),
        .assets => try writeAssets(out_dir),
        .pages => try writePages(self, out_dir),
    }
}

fn writeSitemap(self: Site, out_dir: fs.Dir) !void {
    const zone = tracy.initZone(
        @src(),
        .{ .name = "Write sitemap" },
    );
    defer zone.deinit();

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
        const zone = tracy.initZone(
            @src(),
            .{ .name = "Render Page Loop" },
        );
        defer zone.deinit();

        defer batch_allocator.flush();

        try _render(
            batch_allocator.allocator(),
            self.db,
            self.url_prefix,
            self.site_root,
            entry.filepath,
            entry.slug,
            out_dir,
        );
    }
}

// Assumes that the provided allocator is an arena.
// Reads the page and its associated template from the filesystem
// and writes the rendered page to a file in the out_dir.
fn _render(
    ally: mem.Allocator,
    db: *Database,
    url_prefix: ?[]const u8,
    site_root: []const u8,
    filepath: []const u8,
    slug: []const u8,
    out_dir: fs.Dir,
) !void {
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
        url_prefix,
        html_buffer.writer(),
    );

    try html_buffer.flush();
}

// TODO actual needs don't reflect this initial design. Simplify.
pub const TemplateOption = union(enum) {
    this: void,
    bytes: []const u8,
};

// Write `page` as an html document to the `writer`.
fn renderPage(
    allocator: mem.Allocator,
    p: page.Page,
    tmpl: TemplateOption,
    db: *Database,
    url_prefix: ?[]const u8,
    writer: anytype,
) !void {
    const meta = try p.data(allocator);
    defer meta.deinit(allocator);

    log.debug(
        "rendering ({s})[{s}]",
        .{ meta.title.?, meta.slug },
    );

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

    try markdown.renderStream(
        content,
        .{ .url_prefix = url_prefix },
        content_buf.writer(),
    );

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

        const writer = buf.writer();

        try renderPage(
            testing.allocator,
            page_to_render,
            .{ .bytes = template },
            &db,
            null,
            writer,
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
