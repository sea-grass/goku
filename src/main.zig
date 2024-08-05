const std = @import("std");
const heap = std.heap;
const process = std.process;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const time = std.time;
const c = @import("c");
const tracy = @import("tracy");
const clap = @import("clap");

fn createJsContext(rt: *c.JSRuntime) !*c.JSContext {
    const ctx: *c.JSContext = c.JS_NewContextRaw(rt) orelse return error.CouldNotCreateQuickjsContext;

    c.JS_AddIntrinsicBaseObjects(ctx);
    c.JS_AddIntrinsicDate(ctx);
    c.JS_AddIntrinsicEval(ctx);
    c.JS_AddIntrinsicStringNormalize(ctx);
    c.JS_AddIntrinsicRegExp(ctx);
    c.JS_AddIntrinsicJSON(ctx);
    c.JS_AddIntrinsicProxy(ctx);
    c.JS_AddIntrinsicMapSet(ctx);
    c.JS_AddIntrinsicTypedArrays(ctx);
    c.JS_AddIntrinsicPromise(ctx);
    c.JS_AddIntrinsicBigInt(ctx);

    _ = c.js_init_module_std(ctx, "std") orelse return error.CouldNotInitStdModule;
    _ = c.js_init_module_os(ctx, "os") orelse return error.CouldNotInitOsModule;

    //_ = c.js_init_module_std(ctx, "goku") orelse return error.CouldNotInitGokuModule;
    const goku = c.JS_NewCModule(
        ctx,
        "goku",
        struct {
            export fn init(cctx: ?*c.struct_JSContext, mm: ?*c.struct_JSModuleDef) callconv(.C) c_int {
                var buf: [12]u8 = undefined;
                const abuf = c.JS_NewArrayBuffer(
                    cctx,
                    &buf,
                    buf.len,
                    struct {
                        export fn free(_: ?*c.struct_JSRuntime, _: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {}
                    }.free,
                    null,
                    0,
                );
                if (c.JS_SetModuleExport(cctx, mm, "in", abuf) != 0) {
                    debug.print("WhoooooopsieEE!\n", .{});
                    return -1;
                }
                return 0;
            }
        }.init,
    ) orelse return error.CouldNotInitGokuModule;

    if (c.JS_AddModuleExport(ctx, goku, "in") != 0) {
        return error.CouldNotAddExport;
    }

    return ctx;
}

// We keep a limit on messages shown at the end of the program's execution.
// A value of 16 is an arbitrary low-enough high-enough number where I know
// it would be too messag will be too messy to have more than 16 messages
const num_messages_max = 16;
// The collective length of the messages should not exceed this many bytes.
// Another arbitrary number. This works out to about 64 bytes per message,
// at 16 max messages. Is this enough? Who knows, but it's easy to tweak
// if any issues arise.
const size_messages_max = 1024;

const size_of_alice_txt = 1189000;

// HTML Sitemap looks like this:
// <nav><ul>
// <li><a href="{slug}">{text}</a></li>
// <li><a href="{slug}">{text}</a></li>
// ...
// </ul></nav>
const html_sitemap_preamble =
    \\<nav><ul>
;
const html_sitemap_postamble =
    \\</ul></nav>
;
// I went to a news website's front page and found that the longest
// article title was 128 bytes long. That seems like it could be
// a reasonable limit, but I'd rather just double it out of the gate
// and set the max length to 256.
const sitemap_url_title_len_max = 256;
// It's ridiculous for a URL to exceed this number of bytes
const http_uri_len_max = 2000;
const sitemap_item_surround = "<li><a href=\"\"></a></li>";
const html_sitemap_item_size_max = sitemap_item_surround.len + http_uri_len_max + sitemap_url_title_len_max;

pub fn main() !void {
    tracy.startupProfiler();
    defer tracy.shutdownProfiler();

    tracy.setThreadName("main");
    defer tracy.message("Graceful main thread exit");

    var message_buf: [num_messages_max * @sizeOf([]const u8) + size_messages_max]u8 = undefined;
    var message_stack = try MessageStack.init(&message_buf);
    defer {
        for (message_stack.slice()) |message| {
            debug.print("{s}\n", .{message});
        }
    }

    // What's the point of message stack if this works just as well?
    const start = time.milliTimestamp();
    defer debug.print("Elapsed: {d}ms\n", .{time.milliTimestamp() - start});

    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var tracy_allocator = tracy.TracingAllocator.init(gpa.allocator());
    const unlimited_allocator = tracy_allocator.allocator();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help text and exit.
        \\<str>         The absolute or relative path to your site's source directory.
        \\-o, --out <str>      The directory to place the generated site.
        ,
    );
    var diag: clap.Diagnostic = .{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = unlimited_allocator,
    }) catch |err| {
        // Report useful error on exit
        diag.report(io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        const stderr = io.getStdErr().writer();
        try stderr.print(
            \\Goku - A static site generator
            \\----
            \\Usage:
            \\    goku -h
            \\    goku <site_root> -o <out_dir>
            \\
        ,
            .{},
        );
        try clap.help(io.getStdErr().writer(), clap.Help, &params, .{});
        process.exit(0);
    }

    const site_root = root: {
        if (res.positionals.len < 1) {
            debug.print("Fatal error: Missing required <site_root> argument.\n", .{});
            process.exit(1);
        }

        if (res.positionals.len > 1) {
            const stderr = io.getStdErr().writer();
            try stderr.print(
                \\Goku - A static site generator
                \\----
                \\Usage:
                \\    goku -h
                \\    goku <site_root> -o <out_dir>
                \\
            ,
                .{},
            );
            try clap.help(io.getStdErr().writer(), clap.Help, &params, .{});
            process.exit(1);
        }

        break :root res.positionals[0];
    };

    const out_dir_path = out: {
        if (res.args.out) |out| break :out out;

        const stderr = io.getStdErr().writer();
        try stderr.print(
            \\Goku - A static site generator
            \\----
            \\Usage:
            \\    goku -h
            \\    goku <site_root> -o <out_dir>
            \\
        ,
            .{},
        );
        try clap.help(io.getStdErr().writer(), clap.Help, &params, .{});
        process.exit(1);
    };

    defer debug.print("Site Root {s} -> Out Dir {s}\n", .{ site_root, out_dir_path });

    var page_map = std.StringHashMap(Page).init(unlimited_allocator);
    defer {
        var it = page_map.iterator();
        while (it.next()) |entry| {
            unlimited_allocator.free(entry.key_ptr.*);
            unlimited_allocator.free(entry.value_ptr.*.markdown.frontmatter);
            unlimited_allocator.free(entry.value_ptr.*.markdown.data);
        }
        page_map.deinit();
    }

    var page_it: PageSource = .{
        .root = site_root,
        .subpath = "pages",
    };

    var page_count: u32 = 0;
    while (try page_it.next()) |page| {
        const zone = tracy.initZone(@src(), .{ .name = "Load Page from File" });
        defer zone.deinit();

        const file = try page.openFile();
        defer file.close();

        debug.assert(try file.getPos() == 0);
        const length = try file.getEndPos();

        // alice.txt is 148.57kb. I doubt I'll write a single markdown file
        // longer than the entire Alice's Adventures in Wonderland.
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

        const data = try PageData.fromYamlString(unlimited_allocator, @ptrCast(frontmatter), frontmatter.len);
        defer data.deinit(unlimited_allocator);

        try page_map.put(
            try page_map.allocator.dupe(u8, data.slug),
            .{
                .markdown = .{
                    .frontmatter = try page_map.allocator.dupe(u8, frontmatter),
                    .data = try page_map.allocator.dupe(u8, markdown),
                },
            },
        );

        page_count += 1;
        tracy.plot(u32, "Discovered Page Count", page_count);
    }

    debug.assert(page_count == page_map.count());

    defer debug.print("Discovered ({d}) pages.", .{
        page_map.count(),
    });

    {
        const write_output_zone = tracy.initZone(@src(), .{ .name = "Write Site to Output Dir" });
        defer write_output_zone.deinit();

        // TODO support potentially absolute out dir
        var out_dir = try std.fs.cwd().makeOpenPath(out_dir_path, .{});
        defer out_dir.close();

        // TODO restore skip-to-main-content

        {
            const zone = tracy.initZone(@src(), .{ .name = "Write sitemap" });
            defer zone.deinit();

            var file = try out_dir.createFile("_sitemap.html", .{});
            defer file.close();

            var file_buf = io.bufferedWriter(file.writer());

            try file_buf.writer().writeAll(html_sitemap_preamble);

            {
                var pages_it = page_map.iterator();
                var i: usize = 0;
                while (pages_it.next()) |entry| {
                    debug.assert(i < page_map.count());

                    defer i += 1;

                    var buffer: [html_sitemap_item_size_max]u8 = undefined;
                    var fba = heap.FixedBufferAllocator.init(&buffer);
                    var buf = std.ArrayList(u8).init(fba.allocator());

                    const data = try PageData.fromYamlString(
                        unlimited_allocator,
                        @ptrCast(
                            entry.value_ptr.*.markdown.frontmatter,
                        ),
                        entry.value_ptr.*.markdown.frontmatter.len,
                    );
                    defer data.deinit(unlimited_allocator);

                    const title = data.title orelse "(missing title)";
                    debug.assert(title.len < sitemap_url_title_len_max);

                    const href = entry.key_ptr.*;
                    debug.assert(href.len < http_uri_len_max);

                    try buf.writer().print(
                        \\<li><a href="{s}">{s}</a></li>
                    ,
                        .{ href, title },
                    );

                    try file_buf.writer().writeAll(buf.items);
                }
            }

            try file_buf.writer().writeAll(html_sitemap_postamble);

            try file_buf.flush();
        }

        {
            var file = try out_dir.createFile("htmx.js", .{});
            defer file.close();
            try file.writer().writeAll(@embedFile("htmx.js"));
        }

        {
            var file = try out_dir.createFile("style.css", .{});
            defer file.close();
            try file.writer().writeAll(@embedFile("style.css"));
        }

        const rt: *c.JSRuntime = c.JS_NewRuntime() orelse @panic("Cannot create the QuickJS runtime");
        defer c.JS_FreeRuntime(rt);

        const ctx = createJsContext(rt) catch @panic("Cannot create the QuickJS context");
        defer c.JS_FreeContext(ctx);

        const js_null: c.JSValue = .{
            .tag = c.JS_TAG_NULL,
            .u = .{
                .int32 = 0,
            },
        };
        const ns = c.JS_NewObjectProto(ctx, js_null);
        _ = c.JS_DefinePropertyValueStr(
            ctx,
            ns,
            "version",
            c.JS_NewString(
                ctx,
                "1.1.1",
            ),
            c.JS_PROP_C_W_E,
        );

        // 64 Mo
        //c.JS_SetMemoryLimit(rt, 0x4000000);
        // 64 Kb
        // Not sure what stack size is meaningful, with basic execution I get a stack overflow
        //c.JS_SetMaxStackSize(rt, 0x200000);
        c.JS_SetMaxStackSize(rt, 0x4000000);

        //js_std_set_worker_new_context_func(JS_NewCustomContext);
        c.js_std_init_handlers(rt);
        defer c.js_std_free_handlers(rt);

        c.JS_SetModuleLoaderFunc(rt, null, c.js_module_loader, null);
        c.js_std_add_helpers(ctx, 0, null);

        c.js_std_eval_binary(ctx, &c.qjsc_bin, c.qjsc_bin_size, 0);
        c.js_std_loop(ctx);
        c.js_std_free_handlers(rt);

        var pages_it = page_map.iterator();
        while (pages_it.next()) |entry| {
            const zone = tracy.initZone(@src(), .{ .name = "Render Page Loop" });
            defer zone.deinit();

            const data = try PageData.fromYamlString(
                unlimited_allocator,
                @ptrCast(
                    entry.value_ptr.*.markdown.frontmatter,
                ),
                entry.value_ptr.*.markdown.frontmatter.len,
            );
            defer data.deinit(unlimited_allocator);

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

                        var dir = try out_dir.makeOpenPath(parent[1..], .{});
                        defer dir.close();
                        break :file try dir.createFile(fs.path.basename(file_name_buf.items), .{});
                    }
                }

                break :file try out_dir.createFile(fs.path.basename(file_name_buf.items), .{});
            };
            defer file.close();

            {
                var html_buffer = io.bufferedWriter(file.writer());

                const html_buf = html_buffer.writer();
                {
                    try html_buf.writeAll(
                        \\<!doctype html><html><head>
                    );
                    try html_buf.writeAll(
                        \\<link rel="stylesheet" lang="text/css" href="style.css" />
                    );
                    try html_buf.writeAll("</head><body><div class=\"page\">");
                }

                try html_buf.writeAll(
                    \\<nav hx-get="/_sitemap.html" hx-swap="outerHTML" hx-trigger="load"></nav>
                    ,
                );

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
                        \\</div>
                    );

                    try html_buf.writeAll("<script defer src=\"htmx.js\"></script>");

                    try html_buf.writeAll(
                        \\</body></html>
                    );
                }

                try html_buffer.flush();
            }
        }
    }

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");

}
// MessageStack
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
        const zone = tracy.initZone(@src(), .{ .name = "PageData.fromYamlString" });
        defer zone.deinit();

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
                debug.print("Encountered a yaml parsing error: {s}\nLine: {d} Column: {d}\n", .{
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

    // Can hold up to 1024 directory handles
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
