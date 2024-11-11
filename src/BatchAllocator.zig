//! The BatchAllocator provides a simple interface to
//! process batches of workloads that require an allocator,
//! when you don't want to relinquish all of the allocated
//! memory between batches.

const heap = std.heap;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

const BatchAllocator = @This();

arena: heap.ArenaAllocator,
curr: ?heap.ArenaAllocator = null,

pub fn init(ally: mem.Allocator) BatchAllocator {
    return .{
        .arena = heap.ArenaAllocator.init(ally),
    };
}

/// Free all allocated memory.
pub fn deinit(self: *BatchAllocator) void {
    self.arena.deinit();
}

/// Mark all of the allocated memory for this batch
/// as usable, without freeing it.
pub fn flush(self: *BatchAllocator) void {
    if (self.curr) |*arena| {
        arena.deinit();
        self.curr = null;
    }
}

/// Retrieve the arena allocator for the current batch.
pub fn allocator(self: *BatchAllocator) mem.Allocator {
    if (self.curr) |*arena| return arena.allocator();

    self.curr = heap.ArenaAllocator.init(self.arena.allocator());

    return self.curr.?.allocator();
}

test BatchAllocator {
    var batch_allocator = init(testing.allocator);
    defer batch_allocator.deinit();

    const workload_size = 10;

    for (0..workload_size) |i| {
        var buf = std.ArrayList(u8).init(batch_allocator.allocator());
        defer buf.deinit();

        try buf.writer().print("Work item {d}", .{i});

        batch_allocator.flush();
        try testing.expectEqual(null, batch_allocator.curr);
    }
}
