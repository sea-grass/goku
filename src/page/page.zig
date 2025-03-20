const Data = @import("Data.zig");
const log = std.log.scoped(.Page);
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

pub const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        content: []const u8,
    },

    pub fn data(self: Page, allocator: mem.Allocator) !Data {
        return try Data.fromYamlString(
            allocator,
            self.markdown.frontmatter,
            null,
        );
    }

    test data {
        const frontmatter =
            \\---
            \\title: Hello, world
            \\slug: /
            \\template: foo.html
            \\---
        ;

        const result = try data(
            .{
                .markdown = .{
                    .content = "",
                    .frontmatter = frontmatter,
                },
            },
            testing.allocator,
        );
        defer result.deinit(testing.allocator);

        try testing.expectEqualStrings("Hello, world", result.title.?);
    }

    test "data error" {
        const frontmatter =
            \\---
            \\---
        ;

        const result = data(.{ .markdown = .{ .content = "", .frontmatter = frontmatter } }, testing.allocator);

        try testing.expectError(error.MissingSlug, result);
    }
};

test {
    std.testing.refAllDecls(@This());
}
