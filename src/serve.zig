const std = @import("std");
const httpz = @import("httpz");
const log = std.log.scoped(.serve);
const mem = std.mem;
const process = std.process;
const fs = std.fs;
const fmt = std.fmt;
const heap = std.heap;
const debug = std.debug;

pub fn main() !void {
    var gpa: heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const path = path: {
        var args = try process.argsWithAllocator(allocator);
        defer args.deinit();

        // skip exe name
        _ = args.next();

        const path_arg = args.next() orelse return error.MissingArgs;
        if ((try fs.cwd().statFile(path_arg)).kind != .directory) return error.NotADirectory;

        break :path try allocator.dupe(u8, path_arg);
    };
    defer allocator.free(path);

    log.info("Serve from {s}", .{path});

    const app: App = .{ .path = path };
    var server: App.Server = try .init(allocator, .{
        .address = "127.0.0.1",
        .port = 3000,
    }, &app);
    defer server.deinit();

    log.info("http://{s}:{d}", .{
        server.config.address.?,
        server.config.port.?,
    });
    try server.listen();
}

const App = struct {
    path: []const u8,

    pub const Server = httpz.Server(*const App);

    pub fn handle(self: *const App, req: *httpz.Request, res: *httpz.Response) void {
        const sub_path = filePath(req);
        var dir = fs.cwd().openDir(self.path, .{}) catch {
            res.status = 500;
            res.body = "Not farnd";
            return;
        };
        defer dir.close();

        serveFile(&dir, sub_path, res) catch {
            res.status = 404;
            res.body = "Not foond";
            return;
        };
    }

    fn filePath(req: *httpz.Request) []const u8 {
        if (mem.eql(u8, req.url.path, "/")) {
            return "index.html";
        }

        return req.url.path[1..];
    }

    fn serveFile(dir: *fs.Dir, sub_path: []const u8, res: *httpz.Response) !void {
        var file = try dir.openFile(sub_path, .{});
        defer file.close();

        var fifo: std.fifo.LinearFifo(u8, .{ .Static = 1024 }) = .init();
        try fifo.pump(file.reader(), res.writer());

        if (Mime.match(sub_path)) |mime| {
            res.header("Content-Type", mime.contentType());
        }
    }
};

const Mime = enum {
    wasm,
    javascript,

    pub fn match(file_name: []const u8) ?Mime {
        if (mem.endsWith(u8, file_name, ".wasm.a")) return .wasm;
        if (mem.endsWith(u8, file_name, ".wasm")) return .wasm;
        if (mem.endsWith(u8, file_name, ".js")) return .javascript;
        return null;
    }

    pub fn contentType(mime: Mime) []const u8 {
        return switch (mime) {
            .wasm => "application/wasm",
            .javascript => "text/javascript",
        };
    }
};
