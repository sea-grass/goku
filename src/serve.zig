const std = @import("std");
const zap = @import("zap");
const log = std.log.scoped(.serve);
const mem = std.mem;
const fs = std.fs;
const fmt = std.fmt;
const heap = std.heap;
const debug = std.debug;

const enable_websocket = false;

// Assumes that the `public_folder_path` points to a Goku site with a generated sitemap.html.
// Returns memory owned by the caller (that the caller must free)
fn readSitemap(allocator: mem.Allocator, public_folder_path: []const u8) ![]const u8 {
    var dir = try fs.cwd().openDir(public_folder_path, .{});
    defer dir.close();

    const file = try dir.openFile("_sitemap.html", .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
}

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

    const sitemap = try readSitemap(gpa.allocator(), public_folder);
    defer gpa.allocator().free(sitemap);

    log.info("Sitemap\n{s}\n", .{sitemap});

    var listener = zap.HttpListener.init(.{
        .port = 3000,
        .on_request = onRequest,
        .on_upgrade = if (enable_websocket) onUpgrade else null,
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

fn onUpgrade(r: zap.Request, target_protocol: []const u8) void {
    if (!mem.eql(u8, target_protocol, "websocket")) {
        log.warn("Received illegal protocol: {s}", .{target_protocol});
        r.setStatus(.bad_request);
        r.sendBody("400 Bad Request") catch @panic("Failed to send 400 response");
        return;
    }

    // I don't want to use a global variable, but they have it in their example
    // I think I'll need to make this an endpoint.
}

fn handle(r: zap.Request) !void {
    // TODO websocket feature check will be via a runtime arg
    if (comptime enable_websocket and mem.eql(u8, r.path.?, "/ws")) {
        try handleWebsocket(r);
    } else {
        try handleFallback(r);
    }
}

fn handleWebsocket(r: zap.Request) !void {
    _ = r;
}

// Zap will fall back to this handler if it does not find a matching file in the public folder
// This handler will try to redirect requests for directories to their index.html file, if possible.
fn handleFallback(r: zap.Request) error{ NotFound, Foobie, MalformedRequestPath }!void {
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
