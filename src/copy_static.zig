const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const process = std.process;
const std = @import("std");
pub fn main() !void {
    var buf: [1000 + 2 * fs.max_path_bytes]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);

    var args_it = process.args();

    var static_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (mem.eql(u8, "-from", arg)) {
            static_path = try fba.allocator().dupe(u8, args_it.next() orelse return error.InvalidArguments);
        } else if (mem.eql(u8, "-to", arg)) {
            out_path = try fba.allocator().dupe(u8, args_it.next() orelse return error.InvalidArguments);
        }
    }

    if (static_path == null) return error.MissingStaticPath;
    if (out_path == null) return error.MissingOutPath;

    try copyDirContents(static_path.?, out_path.?);
}

fn copyDirContents(from_path: []const u8, to_path: []const u8) !void {
    var dir = try fs.cwd().openDir(from_path, .{ .iterate = true });
    defer dir.close();

    var out_dir = try fs.cwd().openDir(to_path, .{});
    defer out_dir.close();

    try copyDirContentsHandle(dir, out_dir);
}

/// Caller owns the dir handles.
/// This function will close any new handles it opens.
/// Calls itself recursively to handle copying nested dirs.
fn copyDirContentsHandle(from_dir: fs.Dir, to_dir: fs.Dir) !void {
    var it = from_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                try from_dir.copyFile(entry.name, to_dir, entry.name, .{});
            },
            .directory => {
                var dir = try from_dir.openDir(entry.name, .{ .iterate = true });
                defer dir.close();
                var out_dir = try to_dir.makeOpenPath(entry.name, .{});
                defer out_dir.close();

                try copyDirContentsHandle(dir, out_dir);
            },
            else => return error.CantHandleKind,
        }
    }
}
