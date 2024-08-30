const c = @import("c");
const debug = std.debug;
const heap = std.heap;
const log = std.log.scoped(.page);
const lucide = @import("lucide");
const mem = std.mem;
const mustache = @import("mustache.zig");
const std = @import("std");
const Data = @import("Data.zig");
const Markdown = @import("Markdown.zig");

pub const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        content: []const u8,
    },

    pub fn data(self: Page, allocator: mem.Allocator) !Data {
        return try Data.fromYamlString(
            allocator,
            @ptrCast(self.markdown.frontmatter),
            self.markdown.frontmatter.len,
        );
    }

    // Write `page` as an html document to the `writer`.
    pub const TemplateOption = union(enum) {
        this: void,
        bytes: []const u8,
    };
    pub fn renderStream(self: Page, allocator: mem.Allocator, tmpl: TemplateOption, writer: anytype) !void {
        const meta = try self.data(allocator);
        defer meta.deinit(allocator);

        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        const content = if (meta.allow_html) content: {
            try mustache.Mustache(Data).renderStream(allocator, self.markdown.content, meta, buf.writer());
            break :content buf.items;
        } else self.markdown.content;

        const template = tmpl.bytes;
        const title = meta.title;

        var content_buf = std.ArrayList(u8).init(allocator);
        defer content_buf.deinit();

        {
            var markdown = Markdown.init(allocator);
            defer markdown.deinit();

            try markdown.renderStream(content, content_buf.writer());
        }

        try mustache.Mustache(struct {
            content: []const u8,
            title: []const u8,
        }).renderStream(
            allocator,
            template,
            .{
                .content = content_buf.items,
                .title = title orelse "(missing title)",
            },
            writer,
        );
    }
};
