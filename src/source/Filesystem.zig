const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

pub const Walker = WalkerType(.{ .max_dir_handles = 1024 });
pub fn walker(root: []const u8, subpath: []const u8) Walker {
    return .{ .root = root, .subpath = subpath };
}

pub const WalkerConfig = struct {
    max_dir_handles: comptime_int = 2,
};

// Creates a zero-allocation filesystem walker, to iterate over all files
// in a directory, recursively.
pub fn WalkerType(comptime config: WalkerConfig) type {
    return struct {
        root: []const u8,
        subpath: []const u8,

        done: bool = false,
        dir_handle: ?fs.Dir = null,
        dir_iterator: ?fs.Dir.Iterator = null,

        // Can hold up to `max_dir_handles` directory handles
        buf: [config.max_dir_handles * @sizeOf(fs.Dir)]u8 = undefined,
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

        pub fn next(self: *@This()) !?Entry {
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

        fn ensureBuffer(self: *@This()) !void {
            debug.assert(!self.done);

            if (self.dir_queue == null) {
                self.fba = heap.FixedBufferAllocator.init(&self.buf);
                self.dir_queue = std.ArrayList(fs.Dir).init(self.fba.allocator());
            }

            debug.assert(self.dir_queue != null);
        }

        fn ensureHandle(self: *@This()) !void {
            debug.assert(!self.done);

            if (self.dir_handle == null) {
                var root = root: {
                    if (fs.path.isAbsolute(self.root)) {
                        break :root try fs.openDirAbsolute(self.root, .{});
                    } else {
                        break :root try fs.cwd().openDir(self.root, .{});
                    }
                };
                defer root.close();

                self.dir_handle = try root.openDir(self.subpath, .{ .iterate = true });
            }

            debug.assert(self.dir_handle != null);
        }

        fn ensureIterator(self: *@This()) !void {
            debug.assert(!self.done);
            debug.assert(self.dir_handle != null);

            if (self.dir_iterator == null) {
                self.dir_iterator = self.dir_handle.?.iterate();
            }

            debug.assert(self.dir_iterator != null);
        }

        // TODO how should I test this?
        test next {
            var instance: Walker = .{ .root = ".", .subpath = ".", .done = true };

            try testing.expectEqual(null, try instance.next());
        }

        test ensureBuffer {
            var instance: Walker = .{ .root = ".", .subpath = "." };

            try testing.expectEqual(null, instance.dir_queue);

            try instance.ensureBuffer();

            try testing.expect(instance.dir_queue != null);
        }

        test ensureHandle {
            var instance: Walker = .{
                .root = ".",
                .subpath = ".",
            };

            try testing.expectEqual(null, instance.dir_handle);

            try instance.ensureHandle();

            try testing.expect(instance.dir_handle != null);
        }

        test ensureIterator {
            // TODO Is there a better way to provide an open, iterable directory handle in a test?
            var dir_handle = try fs.cwd().openDir(".", .{ .iterate = true });
            defer dir_handle.close();

            var instance: Walker = .{
                .root = ".",
                .subpath = ".",
                .dir_handle = dir_handle,
            };

            try testing.expectEqual(null, instance.dir_iterator);

            try instance.ensureIterator();

            try testing.expect(instance.dir_iterator != null);
        }
    };
}
