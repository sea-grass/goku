const std = @import("std");
const debug = std.debug;
const heap = std.heap;
const log = std.log.scoped(.page);
const mem = std.mem;
const c = @import("c");
const Data = @import("Data.zig");
const lucide = @import("lucide");
const Markdown = @import("Markdown.zig");
const mustache = @import("mustache.zig");

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

        switch (tmpl) {
            .this => {
                var buf = std.ArrayList(u8).init(allocator);
                defer buf.deinit();

                try mustache.Mustache(Data).renderStream(
                    allocator,
                    self.markdown.content,
                    meta,
                    buf.writer(),
                );

                try writer.writeAll(buf.items);
            },
            else => {},
        }

        // Render page content
        var content_buf = std.ArrayList(u8).init(allocator);
        defer content_buf.deinit();

        // Render content as a mustache doc
        // Then pass that into the markdown renderer

        var markdown = Markdown.init(allocator);
        defer markdown.deinit();

        try markdown.renderStream(
            self.markdown.content,
            content_buf.writer(),
        );

        const content_final = try content_buf.toOwnedSliceSentinel(0);

        try mustache.Mustache(struct {
            content: []const u8,
            title: []const u8,
        }).renderStream(allocator, tmpl.bytes, .{
            .content = content_final,
            .title = meta.title orelse "(missing title)",
        }, writer);
    }
};
