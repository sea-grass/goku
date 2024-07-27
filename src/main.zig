const std = @import("std");
const heap = std.heap;
const process = std.process;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const time = std.time;

const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        data: []const u8,
    },
};

// Can only parse top-level frontmatter key-value pairs.
// Ignores any lines for objects or nested properties.
const FrontmatterIterator = struct {
    buf: []const u8,
    index: usize = 0,
    done: bool = false,
    it: ?mem.SplitIterator(u8, .scalar) = null,

    pub const Entry = struct {
        k: []const u8,
        v: []const u8,
    };
    pub fn next(self: *FrontmatterIterator) !?Entry {
        if (self.done) return null;

        try self.ensureIterator();

        if (self.it.?.next()) |line| {
            var it = mem.splitScalar(u8, line, ':');
            const k = it.next() orelse return null;
            const v = it.next() orelse return null;
            return .{
                .k = k,
                .v = mem.trim(u8, v, " "),
            };
        }

        self.done = true;
        return null;
    }

    pub fn ensureIterator(self: *FrontmatterIterator) !void {
        debug.assert(!self.done);

        if (self.it == null) {
            self.it = mem.splitScalar(u8, self.buf, '\n');
        }

        debug.assert(self.it != null);
    }
};

const PageSource = struct {
    root: []const u8,
    subpath: []const u8,
    done: bool = false,
    dir_handle: ?fs.Dir = null,
    dir_iterator: ?fs.Dir.Iterator = null,

    buf: [1024 * @sizeOf(fs.Dir)]u8 = undefined,
    fba: heap.FixedBufferAllocator = undefined,
    dir_queue: ?std.ArrayList(fs.Dir) = undefined,

    const Entry = struct {
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

        if (try self.dir_iterator.?.next()) |entry| {
            if (entry.kind == .directory) {
                // self.discovery_queue.push(entry.name);
                // temporary "just eat another one"
                // I would expect problems if I thought
                // it wouldn't be short-lived.
                try self.dir_queue.?.append(try self.dir_handle.?.openDir(entry.name, .{ .iterate = true }));
                return self.next();
            } else if (entry.kind == .file) {
                return .{ .dir = self.dir_handle.?, .subpath = entry.name };
            }
        }

        if (self.dir_queue.?.popOrNull()) |dir| {
            self.dir_handle.?.close();
            self.dir_handle = dir;
            self.dir_iterator = null;

            return self.next();
        }

        self.done = true;
        return null;
    }

    pub fn ensureBuffer(self: *PageSource) !void {
        debug.assert(!self.done);

        if (self.dir_queue == null) {
            self.fba = heap.FixedBufferAllocator.init(&self.buf);
            self.dir_queue = std.ArrayList(fs.Dir).init(self.fba.allocator());
        }

        debug.assert(self.dir_queue != null);
    }

    pub fn ensureHandle(self: *PageSource) !void {
        debug.assert(!self.done);

        if (self.dir_handle == null) {
            const root = try if (std.mem.startsWith(u8, self.root, "/")) std.fs.openDirAbsolute(self.root, .{}) else std.fs.cwd().openDir(self.root, .{});
            self.dir_handle = try root.openDir(self.subpath, .{ .iterate = true });
        }

        debug.assert(self.dir_handle != null);
    }

    pub fn ensureIterator(self: *PageSource) !void {
        debug.assert(!self.done);
        debug.assert(self.dir_handle != null);

        if (self.dir_iterator == null) {
            self.dir_iterator = self.dir_handle.?.iterate();
        }

        debug.assert(self.dir_iterator != null);
    }
};

const ParseCodeFenceResult = struct {
    within: []const u8,
    after: []const u8,
};
fn parseCodeFence(comptime fence: []const u8, buf: []u8) ?ParseCodeFenceResult {
    const first_fence = fence ++ "\n";
    const first_index = mem.indexOf(u8, buf, first_fence) orelse return null;

    const second_fence = "\n" ++ fence;
    const second_index = mem.indexOf(u8, buf, "\n" ++ fence) orelse return null;

    if (second_index <= first_index) return null;

    return .{
        .within = buf[first_index + first_fence.len .. second_index],
        .after = buf[second_index + second_fence.len ..],
    };
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try process.argsWithAllocator(allocator);
    defer arg_it.deinit();

    // skip the binary
    _ = arg_it.next();

    const site_root = arg_it.next() orelse {
        std.debug.print("Fatal error: Missing required <site_root> argument.\n", .{});
        process.exit(1);
    };

    const stdout = io.getStdOut().writer();
    try stdout.print("{s}\n", .{site_root});

    var page_map = std.StringHashMap(Page).init(allocator);
    defer {
        var it = page_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*.markdown.frontmatter);
            allocator.free(entry.value_ptr.*.markdown.data);
        }
        page_map.deinit();
    }

    var page_it: PageSource = .{
        .root = site_root,
        .subpath = "pages",
    };

    while (try page_it.next()) |page| {
        const file = try page.openFile();
        defer file.close();

        debug.assert(try file.getPos() == 0);
        const length = try file.getEndPos();

        // alice.txt is 148.57kb. I doubt I'll write a single markdown file
        // longer than the entire Alice's Adventures in Wonderland.
        const size_of_alice_txt = 1189000;
        debug.assert(length < size_of_alice_txt);
        var buffer: [size_of_alice_txt]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buffer);
        var buf = std.ArrayList(u8).init(fba.allocator());
        file.reader().streamUntilDelimiter(buf.writer(), 0, null) catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
        debug.assert(buf.items.len == length);

        const code_fence_result = parseCodeFence("---", buf.items) orelse return error.MissingFrontmatter;
        const frontmatter = code_fence_result.within;
        const markdown = code_fence_result.after;

        var frontmatter_it: FrontmatterIterator = .{
            .buf = frontmatter,
        };

        const slug = slug: while (try frontmatter_it.next()) |kv| {
            if (mem.eql(u8, kv.k, "slug")) {
                if (kv.v.len == 0 or kv.v[0] != '/') return error.InvalidSlug;
                if (kv.v.len > 1 and mem.endsWith(u8, kv.v, "/")) return error.InvalidSlug;

                break :slug kv.v;
            }
        } else {
            return error.MissingSlug;
        };

        try page_map.put(
            try page_map.allocator.dupe(u8, slug),
            .{
                .markdown = .{
                    .frontmatter = try page_map.allocator.dupe(u8, frontmatter),
                    .data = try page_map.allocator.dupe(u8, markdown),
                },
            },
        );

        //time.sleep(1000000000 / 7 * num_pages);
    }

    try stdout.print("Total pages: {d}\n", .{page_map.count()});

    const out_dir = try std.fs.cwd().makeOpenPath("build", .{});

    var sitemap_buf = std.ArrayList(u8).init(allocator);
    defer sitemap_buf.deinit();
    {
        try sitemap_buf.writer().print("<ul>", .{});

        var pages_it = page_map.iterator();
        while (pages_it.next()) |entry| {
            var frontmatter_it: FrontmatterIterator = .{
                .buf = entry.value_ptr.*.markdown.frontmatter,
            };

            const title = title: while (try frontmatter_it.next()) |kv| {
                if (mem.eql(u8, kv.k, "title")) {
                    if (kv.v.len == 0) return error.InvalidTitle;

                    break :title kv.v;
                }
            } else {
                std.debug.print("{s} missing title?!?!?!\n", .{entry.key_ptr.*});
                break :title "(missing title)";
            };

            const href = entry.key_ptr.*;

            try sitemap_buf.writer().print("<li><a href=\"{s}\">{s}</a></li>", .{ href, title });
        }

        try sitemap_buf.writer().print("</ul>", .{});
    }

    var pages_it = page_map.iterator();
    while (pages_it.next()) |entry| {
        var frontmatter_it: FrontmatterIterator = .{
            .buf = entry.value_ptr.*.markdown.frontmatter,
        };

        const slug = slug: while (try frontmatter_it.next()) |kv| {
            if (mem.eql(u8, kv.k, "slug")) {
                if (kv.v.len == 0 or kv.v[0] != '/') return error.InvalidSlug;
                if (kv.v.len > 1 and mem.endsWith(u8, kv.v, "/")) return error.InvalidSlug;

                break :slug kv.v;
            }
        } else {
            return error.MissingSlug;
        };

        var file_name_buffer: [fs.MAX_NAME_BYTES]u8 = undefined;
        var file_name_fba = heap.FixedBufferAllocator.init(&file_name_buffer);
        var file_name_buf = std.ArrayList(u8).init(file_name_fba.allocator());

        debug.assert(slug.len > 0);
        debug.assert(slug[0] == '/');
        if (slug.len > 1) {
            debug.assert(!mem.endsWith(u8, slug, "/"));
            try file_name_buf.appendSlice(slug);
        }
        try file_name_buf.appendSlice("/index.html");

        const file = file: {
            parent: {
                if (fs.path.dirname(file_name_buf.items)) |parent| {
                    debug.assert(parent[0] == '/');
                    if (parent.len == 1) break :parent;

                    try stdout.print("makePath for {s}\n", .{parent});
                    const dir = try out_dir.makeOpenPath(parent[1..], .{});
                    break :file try dir.createFile(fs.path.basename(file_name_buf.items), .{});
                }
            }

            try stdout.print("gunna crudate it: ({s})\n", .{file_name_buf.items});
            break :file try out_dir.createFile(fs.path.basename(file_name_buf.items), .{});
        };
        defer file.close();

        const html_buf = file.writer();
        {
            try html_buf.writeAll(
                \\<!doctype html><html><body>
            );
        }

        {
            try html_buf.writeAll("<main>");
            try html_buf.writeAll("<pre>");
            try html_buf.writeAll(entry.value_ptr.*.markdown.data);
            try html_buf.writeAll("</pre>");
            try html_buf.writeAll("</main>");
        }

        try html_buf.writeAll(sitemap_buf.items);

        {
            try html_buf.writeAll(
                \\</body></html>
            );
        }

        try stdout.print("Wrote out {s}\n", .{file_name_buf.items});
    }

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}

fn fatalExit(comptime reason: []const u8) noreturn {
    std.debug.print("Fatal error: {s}\n", .{reason});
    process.exit(1);
}
