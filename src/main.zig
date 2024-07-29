const std = @import("std");
const heap = std.heap;
const process = std.process;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const time = std.time;
const c = @import("c.zig");

// MessageStack
//
const MessageStack = struct {
    buf: []u8,
    fba: heap.FixedBufferAllocator,
    stack: std.ArrayList([]const u8),

    pub fn init(buf: []u8) !MessageStack {
        var fba = heap.FixedBufferAllocator.init(buf);

        var stack = std.ArrayList([]const u8).init(fba.allocator());
        try stack.ensureTotalCapacity(16);

        return .{
            .buf = buf,
            .fba = fba,
            .stack = stack,
        };
    }

    pub fn push(self: *MessageStack, message: []const u8) !void {
        debug.assert(self.stack.items.len < 16);

        const owned_message = message: {
            if (self.fba.ownsSlice(message)) {
                break :message message;
            } else {
                break :message try self.fba.allocator().dupe(u8, message);
            }
        };

        try self.pushAssumeOwned(owned_message);
    }

    pub fn print(self: *MessageStack, comptime template: []const u8, data: anytype) !void {
        debug.assert(self.stack.items.len < 16);

        var buf = std.ArrayList(u8).init(self.fba.allocator());
        try buf.writer().print(template, data);

        self.pushAssumeOwned(
            try buf.toOwnedSlice(),
        );
    }

    pub fn slice(self: MessageStack) []const []const u8 {
        return self.stack.items;
    }

    pub fn pushAssumeOwned(self: *MessageStack, message: []const u8) void {
        debug.assert(self.stack.items.len < 16);

        self.stack.appendAssumeCapacity(message);
    }
};

const PageData = struct {
    slug: []const u8,
    collection: ?[]const u8 = null,
    title: ?[]const u8 = null,
    date: ?[]const u8 = null,
    options_toc: bool = false,

    // Duplicates slices from the input data. Caller is responsible for
    // calling page_data.deinit(allocator) afterwards.
    pub fn fromYamlString(allocator: mem.Allocator, data: [*c]const u8, len: usize) !PageData {
        var parser: c.yaml_parser_t = undefined;
        const ptr: [*c]c.yaml_parser_t = &parser;

        if (c.yaml_parser_initialize(ptr) == 0) {
            return error.YamlParserInitFailed;
        }
        defer c.yaml_parser_delete(ptr);

        c.yaml_parser_set_input_string(ptr, data, len);

        var done: bool = false;

        var ev: c.yaml_event_t = undefined;
        const ev_ptr: [*c]c.yaml_event_t = &ev;
        var next_scalar_expected: enum {
            key,
            slug,
            title,
            discard,
            date,
            collection,
            description,
            tags,
        } = .key;
        var slug: ?[]const u8 = null;
        var title: ?[]const u8 = null;
        while (!done) {
            if (c.yaml_parser_parse(ptr, ev_ptr) == 0) {
                std.debug.print("Encountered a yaml parsing error: {s}\nLine: {d} Column: {d}\n", .{
                    parser.problem,
                    parser.problem_mark.line + 1,
                    parser.problem_mark.column + 1,
                });
                return error.YamlParseFailed;
            }

            switch (ev.type) {
                c.YAML_STREAM_START_EVENT => {},
                c.YAML_STREAM_END_EVENT => {},
                c.YAML_DOCUMENT_START_EVENT => {},
                c.YAML_DOCUMENT_END_EVENT => {},
                c.YAML_SCALAR_EVENT => {
                    const scalar = ev.data.scalar;
                    const value = scalar.value[0..scalar.length];

                    switch (next_scalar_expected) {
                        .key => {
                            if (mem.eql(u8, value, "slug")) {
                                next_scalar_expected = .slug;
                            } else if (mem.eql(u8, value, "title")) {
                                next_scalar_expected = .title;
                            } else if (mem.eql(u8, value, "collection")) {
                                next_scalar_expected = .collection;
                            } else if (mem.eql(u8, value, "date")) {
                                next_scalar_expected = .date;
                            } else if (mem.eql(u8, value, "tags")) {
                                next_scalar_expected = .tags;
                            } else if (mem.eql(u8, value, "description")) {
                                next_scalar_expected = .description;
                            } else {
                                next_scalar_expected = .discard;
                            }
                        },
                        .slug => {
                            slug = try allocator.dupe(u8, value);
                            next_scalar_expected = .key;
                        },
                        .title => {
                            title = try allocator.dupe(u8, value);
                            next_scalar_expected = .key;
                        },
                        .collection => {
                            next_scalar_expected = .key;
                        },
                        .tags => {
                            next_scalar_expected = .key;
                        },
                        .date => {
                            next_scalar_expected = .key;
                        },
                        .description => {
                            next_scalar_expected = .key;
                        },
                        .discard => {
                            next_scalar_expected = .key;
                        },
                    }
                },
                c.YAML_SEQUENCE_START_EVENT => {},
                c.YAML_SEQUENCE_END_EVENT => {},
                c.YAML_MAPPING_START_EVENT => {},
                c.YAML_MAPPING_END_EVENT => {},
                c.YAML_ALIAS_EVENT => {},
                c.YAML_NO_EVENT => {},
                else => {},
            }

            done = (ev.type == c.YAML_STREAM_END_EVENT);

            c.yaml_event_delete(ev_ptr);
        }

        if (slug == null) return error.MissingSlug;

        return .{
            .slug = slug.?,
            .title = title,
        };
    }

    pub fn deinit(self: PageData, allocator: mem.Allocator) void {
        allocator.free(self.slug);
        if (self.title) |title| {
            allocator.free(title);
        }
    }
};

const Page = union(enum) {
    markdown: struct {
        frontmatter: []const u8,
        data: []const u8,
    },
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
            if (std.mem.startsWith(u8, self.root, "/")) {
                const root = try std.fs.openDirAbsolute(self.root, .{});
                self.dir_handle = try root.openDir(self.subpath, .{ .iterate = true });
            } else {
                // TODO in wasmtime if no directories are mounted, the module panics
                const cwd = std.fs.cwd();
                const root = try cwd.openDir(self.root, .{});
                self.dir_handle = try root.openDir(self.subpath, .{ .iterate = true });
            }
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
    // Enough space for 16 messages and a collective length of 1024
    // bytes. This works out to about 64 bytes per message.
    // Is this enough? Who knows, but it's easy to tweak if any
    // issues arise.
    var message_buf: [16 * @sizeOf([]const u8) + 1024]u8 = undefined;
    var message_stack = try MessageStack.init(&message_buf);
    defer {
        for (message_stack.slice()) |message| {
            std.debug.print("{s}\n", .{message});
        }
    }

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
    try message_stack.print("Site Root {s}", .{site_root});

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

        const data = try PageData.fromYamlString(allocator, @ptrCast(frontmatter), frontmatter.len);
        defer data.deinit(allocator);

        try page_map.put(
            try page_map.allocator.dupe(u8, data.slug),
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
    try message_stack.print("Discovered ({d}) pages.", .{
        page_map.count(),
    });

    // TODO support configurable build output dir
    const out_dir = try std.fs.cwd().makeOpenPath("build", .{});

    var sitemap_buf = std.ArrayList(u8).init(allocator);
    defer sitemap_buf.deinit();
    {
        try sitemap_buf.writer().print("<nav><a id=\"skip-to-main-content\" href=\"#main-content\">Skip to main content</a><ul>", .{});

        var pages_it = page_map.iterator();
        while (pages_it.next()) |entry| {
            const data = try PageData.fromYamlString(
                allocator,
                @ptrCast(
                    entry.value_ptr.*.markdown.frontmatter,
                ),
                entry.value_ptr.*.markdown.frontmatter.len,
            );
            defer data.deinit(allocator);

            const title = data.title orelse "(missing title)";
            const href = entry.key_ptr.*;

            try sitemap_buf.writer().print("<li><a href=\"{s}\">{s}</a></li>", .{ href, title });
        }

        try sitemap_buf.writer().print("</ul></nav>", .{});
    }

    var pages_it = page_map.iterator();
    while (pages_it.next()) |entry| {
        const data = try PageData.fromYamlString(
            allocator,
            @ptrCast(
                entry.value_ptr.*.markdown.frontmatter,
            ),
            entry.value_ptr.*.markdown.frontmatter.len,
        );
        defer data.deinit(allocator);

        const slug = data.slug;

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
            make_parent: {
                if (fs.path.dirname(file_name_buf.items)) |parent| {
                    debug.assert(parent[0] == '/');
                    if (parent.len == 1) break :make_parent;

                    const dir = try out_dir.makeOpenPath(parent[1..], .{});
                    break :file try dir.createFile(fs.path.basename(file_name_buf.items), .{});
                }
            }

            break :file try out_dir.createFile(fs.path.basename(file_name_buf.items), .{});
        };
        defer file.close();

        const html_buf = file.writer();
        {
            try html_buf.writeAll(
                \\<!doctype html><html><head>
            );
            try html_buf.writeAll("<style>" ++ @embedFile("style.css") ++ "</style>");
            try html_buf.writeAll("</head><body><div class=\"page\">");
        }

        try html_buf.writeAll(sitemap_buf.items);

        {
            try html_buf.writeAll("<section class=\"meta\">");
            try html_buf.writeAll(entry.value_ptr.*.markdown.frontmatter);
            try html_buf.writeAll("</section>");
        }

        {
            try html_buf.writeAll("<main><a href=\"#main-content\" id=\"main-content\" tabindex=\"-1\"></a>");
            try html_buf.writeAll(mem.trim(u8, entry.value_ptr.*.markdown.data, " \n"));
            try html_buf.writeAll("</main>");
        }

        {
            try html_buf.writeAll(
                \\</div></body></html>
            );
        }

        try stdout.print("{s}\n", .{file_name_buf.items});
    }

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");

}

fn fatalExit(comptime reason: []const u8) noreturn {
    std.debug.print("Fatal error: {s}\n", .{reason});
    process.exit(1);
}
