const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;

const PageSource = @This();

root: []const u8,
subpath: []const u8,
done: bool = false,
dir_handle: ?fs.Dir = null,
dir_iterator: ?fs.Dir.Iterator = null,

// Can hold up to 1024 directory handles
buf: [1024 * @sizeOf(fs.Dir)]u8 = undefined,
fba: heap.FixedBufferAllocator = undefined,
dir_queue: ?std.ArrayList(fs.Dir) = null,

pub const Entry = struct {
    dir: fs.Dir,
    subpath: []const u8,

    pub fn realpath(self: Entry, buf: []u8) ![]const u8 {
        return try self.dir.realpath(self.subpath, buf);
    }

    pub fn openFile(self: Entry) !fs.File {
        return try self.dir.openFile(self.subpath, .{});
    }
};

pub fn next(self: *PageSource) !?Entry {
    if (self.done) return null;

    try self.ensureBuffer();
    try self.ensureHandle();
    try self.ensureIterator();

    const file: ?Entry = file: {
        if (try self.dir_iterator.?.next()) |entry| {
            if (entry.kind == .directory) {
                try self.dir_queue.?.append(try self.dir_handle.?.openDir(entry.name, .{ .iterate = true }));
                // temporary "just eat another one"
                // I would expect problems if I thought
                // it wouldn't be short-lived.
                break :file try self.next();
            } else {
                break :file .{ .dir = self.dir_handle.?, .subpath = entry.name };
            }
        }

        break :file null;
    };

    if (file) |f| return f;

    if (self.dir_queue.?.popOrNull()) |dir| {
        self.dir_handle.?.close();
        self.dir_handle = dir;
        self.dir_iterator = null;

        return try self.next();
    }

    self.done = true;
    return null;
}

fn ensureBuffer(self: *PageSource) !void {
    debug.assert(!self.done);

    if (self.dir_queue == null) {
        self.fba = heap.FixedBufferAllocator.init(&self.buf);
        self.dir_queue = std.ArrayList(fs.Dir).init(self.fba.allocator());
    }

    debug.assert(self.dir_queue != null);
}

fn ensureHandle(self: *PageSource) !void {
    debug.assert(!self.done);

    if (self.dir_handle == null) {
        if (std.mem.startsWith(u8, self.root, "/")) {
            var root = try std.fs.openDirAbsolute(self.root, .{});
            defer root.close();
            self.dir_handle = try root.openDir(self.subpath, .{ .iterate = true });
        } else {
            // TODO in wasmtime if no directories are mounted, the module panics
            var root = try fs.cwd().openDir(self.root, .{});
            defer root.close();
            self.dir_handle = try root.openDir(self.subpath, .{ .iterate = true });
        }
    }

    debug.assert(self.dir_handle != null);
}

fn ensureIterator(self: *PageSource) !void {
    debug.assert(!self.done);
    debug.assert(self.dir_handle != null);

    if (self.dir_iterator == null) {
        self.dir_iterator = self.dir_handle.?.iterate();
    }

    debug.assert(self.dir_iterator != null);
}
