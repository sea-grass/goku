const std = @import("std");
const Cli = @import("Cli.zig");
const heap = std.heap;

pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
};

pub fn main() !void {
    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    const unlimited_allocator = gpa.allocator();

    try Cli.main(unlimited_allocator);
}
