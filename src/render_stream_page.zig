const std = @import("std");
const io = std.io;
const mem = std.mem;
const Markdown = @import("Markdown.zig");
const Page = @import("page.zig").Page;

// Write `page` as an html document to the `writer`.
pub fn renderStreamPage(allocator: mem.Allocator, page: Page, writer: anytype) !void {
    try writeHead(writer);
    try writeNav(writer);
    try writeMeta(page.markdown.frontmatter, writer);
    try writeMain(
        allocator,
        page.markdown.data,
        writer,
    );
    try writePostamble(writer);
}

fn writeHead(writer: anytype) !void {
    try writer.writeAll(
        \\<!doctype html><html><head>
    );
    try writer.writeAll(
        \\<link rel="stylesheet" lang="text/css" href="/style.css" />
    );
    try writer.writeAll("</head><body><div class=\"page\">");
}

fn writeNav(writer: anytype) !void {
    try writer.writeAll(
        \\<nav hx-get="/_sitemap.html" hx-swap="outerHTML" hx-trigger="load"></nav>
        ,
    );
}

fn writeMeta(frontmatter: []const u8, writer: anytype) !void {
    try writer.writeAll("<section class=\"meta\">");
    try writer.writeAll(frontmatter);
    try writer.writeAll("</section>");
}

fn writeMain(allocator: mem.Allocator, markdown: []const u8, writer: anytype) !void {
    try writer.writeAll("<main><a href=\"#main-content\" id=\"main-content\" tabindex=\"-1\"></a>");

    var parser = Markdown.init(allocator);
    defer parser.deinit();

    try parser.renderStream(markdown, writer);

    try writer.writeAll("</main>");
}

fn writePostamble(writer: anytype) !void {
    try writer.writeAll(
        \\</div>
    );

    try writer.writeAll("<script defer src=\"/htmx.js\"></script>");

    try writer.writeAll(
        \\</body></html>
    );
}
