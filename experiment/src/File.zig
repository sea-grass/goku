const File = @This();

// absolute path (realpath)
path: []const u8,

/// Maximum page file size (100KB)
pub const max_bytes = 100 * 1024;

pub fn readAll(file: File, allocator: mem.Allocator) ![]const u8 {
    var handle = try fs.openFileAbsolute(file.path, .{});
    defer handle.close();
    return try handle.readToEndAlloc(allocator, max_bytes);
}

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
