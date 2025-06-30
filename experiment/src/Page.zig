file: File,
node: std.SinglyLinkedList.Node = .{},

pub const SplitError = error{
    PageIsMissingFrontmatterFence,
};

pub const SplitResult = struct { []const u8, []const u8 };

pub fn split(file_content: []const u8) SplitError!SplitResult {
    if (!mem.eql(u8, file_content[0..3], "---")) return error.PageIsMissingFrontmatterFence;
    const fence_index = mem.indexOfPos(u8, file_content, 3, "---") orelse return error.PageIsMissingFrontmatterFence;

    const frontmatter = mem.trim(u8, file_content[3..fence_index], "\n");
    const content = mem.trimLeft(u8, file_content[fence_index + 3 ..], "\n");

    return .{ frontmatter, content };
}

const File = @import("File.zig");
const std = @import("std");
const mem = std.mem;
