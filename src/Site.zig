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
const html_sitemap_item_size_max = (sitemap_item_surround.len +
    http_uri_len_max +
    sitemap_url_title_len_max);

const get_pages = .{
    .stmt =
    \\SELECT slug, title FROM pages;
    ,
    .type = struct { slug: []const u8, title: []const u8 },
};
const get_pages2 = .{
    .stmt =
    \\SELECT slug, filepath FROM pages;
    ,
    .type = struct { slug: []const u8, filepath: []const u8 },
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

const Part = enum {
    sitemap,
    assets,
    pages,
};
pub fn write(self: Site, part: Part, out_dir: fs.Dir) !void {
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

    try file_buf.writer().writeAll(html_sitemap_preamble);

    {
        var get_stmt = try self.db.db.prepare(get_pages.stmt);
        defer get_stmt.deinit();

        var it = try get_stmt.iterator(
            get_pages.type,
            .{},
        );

        var arena = heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
            var buffer: [html_sitemap_item_size_max]u8 = undefined;
            var fba = heap.FixedBufferAllocator.init(
                &buffer,
            );
            var buf = std.ArrayList(u8).init(
                fba.allocator(),
            );

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

const WritePagesIterator = struct {
    arena: heap.ArenaAllocator,
    stmt: Database.StatementType(.{}, get_pages2.stmt),
    it: Database.Iterator(get_pages2.type),

    pub fn init(ally: mem.Allocator, db: *Database) !WritePagesIterator {
        var stmt = try db.db.prepare(get_pages2.stmt);
        errdefer stmt.deinit();

        const it = try stmt.iterator(get_pages2.type, .{});

        var arena = heap.ArenaAllocator.init(ally);
        errdefer arena.deinit();

        return .{
            .arena = arena,
            .stmt = stmt,
            .it = it,
        };
    }

    pub fn deinit(self: *WritePagesIterator) void {
        self.arena.deinit();
        self.stmt.deinit();
    }

    pub fn next(self: *WritePagesIterator) !?get_pages2.type {
        return try self.it.nextAlloc(
            self.arena.allocator(),
            .{},
        );
    }
};

// I need to come up for a name for the following allocation strategy.
// allocator (provided out-of-scope) ->
//  arena allocator (lifetime only for current scope) ->
//      arena allocator (lifetime per iteration)
// The idea is that each iteration will take about the same amount of memory.
// Maybe something like:
// allocator (lifetime beyond this scope) ->
//  buf (lifetime for current scope) ->
//      chunk (lifetime per iteration)
// Using the language that we retain a buffer via the allocator and then
// rent out a chunk to each iteration?
fn writePages(self: Site, out_dir: fs.Dir) !void {
    var it = try WritePagesIterator.init(
        self.allocator,
        self.db,
    );
    defer it.deinit();

    var buf = heap.ArenaAllocator.init(self.allocator);
    defer buf.deinit();

    while (try it.next()) |entry| {
        const zone = tracy.initZone(
            @src(),
            .{ .name = "Render Page Loop" },
        );
        defer zone.deinit();

        var chunk = heap.ArenaAllocator.init(buf.allocator());
        defer chunk.deinit();

        try _render(
            chunk.allocator(),
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
