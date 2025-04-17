const std = @import("std");
const process = std.process;
const cli = @import("Cli.zig");
const heap = std.heap;
const goku = @import("goku.zig");

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

    var iter = try process.ArgIterator.initWithAllocator(unlimited_allocator);
    defer iter.deinit();

    // skip exe name
    _ = iter.next();

    const command: cli.Command = try cli.Command.parse(&iter) orelse return cli.printHelp();
    switch (command) {
        .build => |args| {
            try goku.build(unlimited_allocator, args);
        },
        .preview => |args| {
            try goku.preview(unlimited_allocator, args);
        },
        else => {
            std.log.info("Some other command", .{});
        },
    }
}
