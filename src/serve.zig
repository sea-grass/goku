const std = @import("std");
const zap = @import("zap");
const log = std.log.scoped(.serve);
const mem = std.mem;
const fs = std.fs;
const fmt = std.fmt;
const heap = std.heap;
const debug = std.debug;

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len != 2) {
        return error.MissingArgs;
    }

    const public_folder = args[1];
    const result = try fs.cwd().statFile(public_folder);
    debug.assert(result.kind == .directory);

    var listener = zap.HttpListener.init(.{
        .port = 3000,
        .on_request = onRequest,
        .log = true,
        .max_clients = 10,
        .max_body_size = 1 * 1024, // careful here  HUH ????
        .public_folder = public_folder,
    });

    zap.enableDebugLog();
    try listener.listen();

    log.info("Running at http://localhost:3000", .{});

    zap.start(.{
        .threads = 1,
        .workers = 1,
    });
}

fn onRequest(r: zap.Request) void {
    handle(r) catch |err| switch (err) {
        error.NotFound => {
            r.setStatus(.not_found);
            r.sendBody("Not found") catch {};
        },
        else => {},
    };
}

// Zap will fall back to this handler if it does not find a matching file in the public folder
// This handler will try to redirect requests for directories to their index.html file, if possible.
fn handle(r: zap.Request) error{ NotFound, Foobie, MalformedRequestPath }!void {
    const path = r.path.?;

    var it = mem.splitBackwardsScalar(u8, path, '/');
    const last_part = it.next() orelse return error.MalformedRequestPath;

    if (mem.lastIndexOfScalar(u8, last_part, '.') == null) {
        // honestly, this isn't even the best approach...what if the url just has a `.` in it?
        // TODO probably a better constant to use for max url length
        var buf: [fs.max_path_bytes]u8 = undefined;
        const new_path = fmt.bufPrint(&buf, "{s}/{s}", .{ path, "index.html" }) catch return error.Foobie;
        r.redirectTo(new_path, .temporary_redirect) catch return error.Foobie;
    }

    return error.NotFound;
}
