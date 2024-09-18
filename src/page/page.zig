const mem = std.mem;
const log = std.log.scoped(.Page);
const std = @import("std");
const Data = @import("Data.zig");

pub const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        content: []const u8,
    },

    pub fn data(self: Page, allocator: mem.Allocator) !Data {
        var diag: Data.Diagnostics = undefined;
        return Data.fromYamlString(
            allocator,
            self.markdown.frontmatter,
            &diag,
        ) catch |err| {
            diag.printErr(log);
            return err;
        };
    }
};
