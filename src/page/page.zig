const mem = std.mem;
const std = @import("std");
const Data = @import("Data.zig");

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
};
