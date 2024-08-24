const std = @import("std");
const mem = std.mem;
const Data = @import("Data.zig");
const Parser = @import("parser.zig").Parser;

pub const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        data: []const u8,
    },

    // Write `page` as an html document to the `writer`.
    pub fn renderStream(self: Page, allocator: mem.Allocator, writer: anytype) !void {
        const data = try Data.fromYamlString(
            allocator,
            @ptrCast(self.markdown.frontmatter),
            self.markdown.frontmatter.len,
        );
        defer data.deinit(allocator);

        try Parser(@TypeOf(writer)).parse(allocator, self, writer);
    }
};
