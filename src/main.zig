const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const process = std.process;
const time = std.time;
const tracy = @import("tracy");
const clap = @import("clap");
const Page = @import("page.zig").Page;
const PageData = @import("PageData.zig");
const PageSource = @import("PageSource.zig");
const parseCodeFence = @import("parse_code_fence.zig").parseCodeFence;
const renderStreamPage = @import("render_stream_page.zig").renderStreamPage;

const size_of_alice_txt = 1189000;

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

const PageHashMap = struct {
    map: std.StringHashMap(Page),

    pub fn init(allocator: mem.Allocator) PageHashMap {
        return .{
            .map = std.StringHashMap(Page).init(allocator),
        };
    }

    pub fn deinit(self: *PageHashMap) void {
        var it = self.iterator();
        while (it.next()) |entry| {
            self.map.allocator.free(entry.key_ptr.*);
            self.map.allocator.free(entry.value_ptr.*.markdown.frontmatter);
            self.map.allocator.free(entry.value_ptr.*.markdown.data);
        }
        self.map.deinit();
    }

    pub fn putCopy(self: *PageHashMap, slug: []const u8, frontmatter: []const u8, markdown: []const u8) !void {
        try self.map.put(
            try self.map.allocator.dupe(u8, slug),
            .{
                .markdown = .{
                    .frontmatter = try self.map.allocator.dupe(u8, frontmatter),
                    .data = try self.map.allocator.dupe(u8, markdown),
                },
            },
        );
    }

    pub const Iterator = std.StringHashMap(Page).Iterator;
    pub fn iterator(self: *PageHashMap) Iterator {
        return self.map.iterator();
    }

    pub const Size = std.StringHashMap(Page).Size;
    pub fn count(self: PageHashMap) Size {
        return self.map.count();
    }
};

pub fn main() !void {
    const start = time.milliTimestamp();
    defer debug.print("Elapsed: {d}ms\n", .{time.milliTimestamp() - start});

    tracy.startupProfiler();
    defer tracy.shutdownProfiler();

    tracy.setThreadName("main");
    defer tracy.message("Graceful main thread exit");

    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa.deinit()) {
        .leak => {
            debug.print("Memory leak...\n", .{});
        },
        else => {},
    };

    var tracy_allocator = tracy.TracingAllocator.init(gpa.allocator());
    const unlimited_allocator = tracy_allocator.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help text and exit.
        \\<str>         The absolute or relative path to your site's source directory.
        \\-o, --out <str>      The directory to place the generated site.
        ,
    );
    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = unlimited_allocator,
    }) catch |err| {
        // Report useful error on exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
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
        process.exit(0);
    }

    const site_root = if (res.positionals.len == 1) res.positionals[0] else {
        if (res.positionals.len < 1) {
            debug.print("Fatal error: Missing required <site_root> argument.\n", .{});
            process.exit(1);
        }

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
        process.exit(1);
    };

    const out_dir_path = if (res.args.out) |out| out else {
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
        process.exit(1);
    };

    defer debug.print("Site Root {s} -> Out Dir {s}\n", .{ site_root, out_dir_path });

    var page_map = PageHashMap.init(unlimited_allocator);
    defer page_map.deinit();

    var page_count: u32 = 0;

    var page_load_allocator = heap.ArenaAllocator.init(unlimited_allocator);
    defer page_load_allocator.deinit();

    var page_it: PageSource = .{
        .root = site_root,
        .subpath = "pages",
    };
    while (try page_it.next()) |page| {
        const zone = tracy.initZone(@src(), .{ .name = "Load Page from File" });
        defer zone.deinit();

        const file = try page.openFile();
        defer file.close();

        debug.assert(try file.getPos() == 0);
        const length = try file.getEndPos();

        // alice.txt is 148.57kb. I doubt I'll write a single markdown file
        // longer than the entire Alice's Adventures in Wonderland.
        debug.assert(length < size_of_alice_txt);
        var buffer: [size_of_alice_txt]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buffer);
        var buf = std.ArrayList(u8).init(fba.allocator());
        file.reader().streamUntilDelimiter(buf.writer(), 0, null) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
        debug.assert(buf.items.len == length);

        const code_fence_result = parseCodeFence(buf.items) orelse return error.MissingFrontmatter;
        const frontmatter = code_fence_result.within;
        const markdown = code_fence_result.after;

        const allocator = page_load_allocator.allocator();
        const data = try PageData.fromYamlString(allocator, @ptrCast(frontmatter), frontmatter.len);
        defer data.deinit(allocator);

        try page_map.putCopy(data.slug, frontmatter, markdown);

        page_count += 1;
        tracy.plot(u32, "Discovered Page Count", page_count);
    }

    debug.assert(page_count == page_map.count());

    defer debug.print("Discovered ({d}) pages.", .{
        page_map.count(),
    });

    {
        const write_output_zone = tracy.initZone(@src(), .{ .name = "Write Site to Output Dir" });
        defer write_output_zone.deinit();

        // TODO support potentially absolute out dir
        var out_dir = try std.fs.cwd().makeOpenPath(out_dir_path, .{});
        defer out_dir.close();

        // TODO restore skip-to-main-content

        {
            const zone = tracy.initZone(@src(), .{ .name = "Write sitemap" });
            defer zone.deinit();

            var file = try out_dir.createFile("_sitemap.html", .{});
            defer file.close();

            var file_buf = io.bufferedWriter(file.writer());

            try file_buf.writer().writeAll(html_sitemap_preamble);

            {
                var pages_it = page_map.iterator();
                var i: usize = 0;
                while (pages_it.next()) |entry| {
                    debug.assert(i < page_map.count());

                    defer i += 1;

                    var buffer: [html_sitemap_item_size_max]u8 = undefined;
                    var fba = heap.FixedBufferAllocator.init(&buffer);
                    var buf = std.ArrayList(u8).init(fba.allocator());

                    const data = try PageData.fromYamlString(
                        unlimited_allocator,
                        @ptrCast(
                            entry.value_ptr.*.markdown.frontmatter,
                        ),
                        entry.value_ptr.*.markdown.frontmatter.len,
                    );
                    defer data.deinit(unlimited_allocator);

                    const title = data.title orelse "(missing title)";
                    debug.assert(title.len < sitemap_url_title_len_max);

                    const href = entry.key_ptr.*;
                    debug.assert(href.len < http_uri_len_max);

                    try buf.writer().print(
                        \\<li><a href="{s}">{s}</a></li>
                    ,
                        .{ href, title },
                    );

                    try file_buf.writer().writeAll(buf.items);
                }
            }

            try file_buf.writer().writeAll(html_sitemap_postamble);

            try file_buf.flush();
        }

        {
            var file = try out_dir.createFile("htmx.js", .{});
            defer file.close();
            try file.writer().writeAll(@embedFile("assets/htmx.js"));
        }

        {
            var file = try out_dir.createFile("style.css", .{});
            defer file.close();
            try file.writer().writeAll(@embedFile("assets/style.css"));
        }

        // We create an arena allocator for processing the pages. To avoid
        // allocating/freeing memory at the start/end of each page render,
        // we let the memory grow according to the maximum needs of a page
        // and keep it around until we're done rendering.
        var page_buf_allocator = heap.ArenaAllocator.init(unlimited_allocator);
        defer page_buf_allocator.deinit();

        var pages_it = page_map.iterator();
        while (pages_it.next()) |entry| {
            const zone = tracy.initZone(@src(), .{ .name = "Render Page Loop" });
            defer zone.deinit();

            var this_page_allocator = heap.ArenaAllocator.init(page_buf_allocator.allocator());
            defer this_page_allocator.deinit();

            const data = try PageData.fromYamlString(
                this_page_allocator.allocator(),
                @ptrCast(
                    entry.value_ptr.*.markdown.frontmatter,
                ),
                entry.value_ptr.*.markdown.frontmatter.len,
            );
            defer data.deinit(this_page_allocator.allocator());

            const slug = data.slug;

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

            try renderStreamPage(
                this_page_allocator.allocator(),
                entry.value_ptr.*,
                html_buffer.writer(),
            );

            try html_buffer.flush();
        }
    }

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}
