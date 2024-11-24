const std = @import("std");
const zap = @import("zap");
const log = std.log.scoped(.serve);
const mem = std.mem;
const process = std.process;
const fs = std.fs;
const fmt = std.fmt;
const heap = std.heap;
const debug = std.debug;

const enable_websocket = false;
const log_sitemap = false;

// This is the shape of the program architecture that I envision.
const shape = .{
    .serve_bin = .{
        .zap_server = .{
            .serve_static_files = {},
            .livereload_websocket_handler = {},
            .socket_for_rebuild_notification = {},
        },
        .inotifywait = .{
            .folder_watcher = {},
            .socket_for_build_complete_notification = {},
        },
        .goku_lib = .{
            .socket_to_trigger_rebuild = {},
        },
    },
};

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var buf: [fs.max_path_bytes]u8 = undefined;
    const public_folder = try parsePublicFolder(&buf);

    if (log_sitemap) {
        const sitemap = try readSitemap(gpa.allocator(), public_folder);
        defer gpa.allocator().free(sitemap);

        log.info("Sitemap\n{s}\n", .{sitemap});
    }

    var server: Server = undefined;
    server.init(.{
        .public_folder = public_folder,
        .allocator = gpa.allocator(),
        .port = 3000,
    });
    defer server.deinit();

    try server.start();
}

fn parsePublicFolder(buf: []u8) ![:0]const u8 {
    var args = process.args();

    // skip exe name
    _ = args.next();

    if (args.next()) |public_folder| {
        const result = try fs.cwd().statFile(public_folder);
        debug.assert(result.kind == .directory);

        return try fmt.bufPrintZ(buf, "{s}", .{public_folder});
    }

    return error.MissingArgs;
}

// Assumes that the `public_folder_path` points to a Goku site with a generated sitemap.html.
// Returns memory owned by the caller (that the caller must free)
fn readSitemap(allocator: mem.Allocator, public_folder_path: []const u8) ![]const u8 {
    var dir = try fs.cwd().openDir(public_folder_path, .{});
    defer dir.close();

    const file = try dir.openFile("_sitemap.html", .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, 1 * 1024 * 1024);
}

const Server = struct {
    allocator: mem.Allocator,
    listener: zap.Endpoint.Listener,
    public: Public,

    const Public = struct {
        public_folder: []const u8,
        ep: zap.Endpoint,

        pub fn init(public_folder: []const u8) Public {
            return .{
                .ep = zap.Endpoint.init(.{
                    .path = "/",
                    .get = get,
                }),
                .public_folder = public_folder,
            };
        }

        pub fn deinit(self: Public) void {
            _ = self;
        }

        pub fn endpoint(self: *Public) *zap.Endpoint {
            return &self.ep;
        }

        fn get(ep: *zap.Endpoint, r: zap.Request) void {
            getWithError(
                @fieldParentPtr("ep", ep),
                r,
            ) catch {};
        }

        fn filePath(self: *Public, path: []const u8, buf: []u8) ![]const u8 {
            var fba = heap.FixedBufferAllocator.init(buf);

            return try fs.path.join(
                fba.allocator(),
                &.{ self.public_folder, path },
            );
        }

        fn getWithError(self: *Public, r: zap.Request) !void {
            if (r.path == null) return error.MissingPath;

            var buf: [fs.max_path_bytes]u8 = undefined;
            const path = try self.filePath(r.path.?, &buf);

            if (mem.endsWith(u8, path, ".html")) {
                try r.setHeader("Cache-Control", "no-cache");
            }

            r.sendFile(path) catch |err| switch (err) {
                error.SendFile => {
                    return handleFallback(r);
                },
                else => return err,
            };
        }

        fn handleFallback(r: zap.Request) error{ NotFound, Foobie, MalformedRequestPath }!void {
            if (!mem.endsWith(u8, r.path.?, "/")) {
                var buf: [fs.max_path_bytes]u8 = undefined;
                const path: []const u8 = fmt.bufPrint(&buf, "{s}/", .{r.path.?}) catch return error.Foobie;
                r.redirectTo(path, .temporary_redirect) catch return error.Foobie;
            }

            return error.NotFound;
        }
    };

    pub const Options = struct {
        allocator: mem.Allocator,
        port: u16,
        public_folder: []const u8,
    };

    pub fn init(self: *Server, opts: Options) void {
        zap.mimetypeRegister("wasm", "application/wasm");

        self.* = .{
            .allocator = opts.allocator,
            .listener = zap.Endpoint.Listener.init(opts.allocator, .{
                .port = opts.port,
                .on_request = onRequest,
                .log = true,
                .max_clients = 10,
                .max_body_size = 1 * 1024, // careful here  HUH ????
            }),
            .public = Public.init(opts.public_folder),
        };

        self.listener.register(self.public.endpoint()) catch
            @panic("Could not register public_folder endpoint");
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
        self.public.deinit();
    }

    pub fn start(self: *Server) !void {
        zap.enableDebugLog();
        try self.listener.listen();

        log.info("Running at http://localhost:3000", .{});

        zap.start(.{
            .threads = 1,
            .workers = 1,
        });
    }

    fn onRequest(r: zap.Request) void {
        r.setStatus(.not_found);
        r.sendBody("Not found") catch {};
    }
};
