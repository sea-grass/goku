const std = @import("std");
const Cli = @import("Cli.zig");
const heap = std.heap;
const tracy = @import("tracy");

pub const std_options: std.Options = .{
    .log_level = switch (@import("builtin").mode) {
        .Debug => .debug,
        else => .info,
    },
};

pub fn main() !void {
    var gpa: heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    tracy.startupProfiler();
    defer tracy.shutdownProfiler();

    tracy.setThreadName("main");
    defer tracy.message("Graceful main thread exit");

    var tracy_allocator = tracy.TracingAllocator.init(gpa.allocator());
    const unlimited_allocator = tracy_allocator.allocator();

    try Cli.main(unlimited_allocator);
}
