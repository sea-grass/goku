const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const js = @import("js.zig");
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.mustache);
const htm = @import("htm");
const vhtml = @import("vhtml");
const lucide = @import("lucide");
const math = std.math;
const mem = std.mem;
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const ComponentAssets = @import("Site.zig").ComponentAssets;

pub fn renderStream(allocator: mem.Allocator, template: []const u8, context: anytype, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mustache_writer = MustacheWriterType(@TypeOf(context)).init(
        arena.allocator(),
        context,
        writer.any(),
    );

    try mustache_writer.write(template);
}

test renderStream {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var styles_buf = std.ArrayList(u8).init(testing.allocator);
    defer styles_buf.deinit();

    var scripts_buf = std.ArrayList(u8).init(testing.allocator);
    defer scripts_buf.deinit();

    const template = "{{title}}";

    var db = try @import("Database.zig").init(testing.allocator);
    try storage.Page.init(&db);
    try storage.Template.init(&db);
    defer db.deinit();

    try renderStream(
        testing.allocator,
        template,
        .{
            .db = db,
            .site_root = "/",
            .data = .{
                .title = "foo",
                .slug = "/foo",
            },
        },
        buf.writer(),
        styles_buf.writer(),
        scripts_buf.writer(),
    );

    try testing.expectEqualStrings("foo", buf.items);
}

fn GetHandleType(comptime UserContext: type) type {
    return struct {
        user_context: UserContext,

        const GetHandle = @This();

        pub fn getKnown(get_handle: *GetHandle, arena: mem.Allocator, key: []const u8) !?[]const u8 {
            // These are known goku constants that are expected to be available during page rendering.
            const context_keys = &.{ "content", "site_root" };

            // At runtime, if a template tries to get one of these keys, we look for it in Context.
            // If the key is found, we populate the buf with a copy.
            // Otherwise, we return a runtime error.
            // ---
            // Really, in the application there are two kinds of rendering
            // the preprocess pass on the content and the final rendering pass
            // where the content is known.
            // In the first, these context keys are not present - ideally
            // we encode that logic where this is being called, rather than
            // in two separate places
            inline for (context_keys) |context_key| {
                if (mem.eql(u8, key, context_key)) {
                    if (!@hasField(UserContext, context_key)) return error.ContextMissingRequestedKey;

                    return try arena.dupeZ(u8, @field(get_handle.user_context, context_key));
                }
            }

            return null;
        }

        fn getData(get_handle: *GetHandle, arena: mem.Allocator, key: []const u8) !?[]const u8 {
            inline for (@typeInfo(@TypeOf(get_handle.user_context.data)).@"struct".fields) |f| {
                if (mem.eql(u8, key, f.name)) {
                    switch (@typeInfo(f.type)) {
                        .optional => {
                            const value = @field(get_handle.user_context.data, f.name);

                            if (value) |v| {
                                return try arena.dupeZ(u8, v);
                            }

                            return "";
                        },
                        .bool => {
                            return if (@field(get_handle.user_context.data, f.name)) "true" else "false";
                        },
                        else => {
                            return try arena.dupeZ(
                                u8,
                                @field(get_handle.user_context.data, f.name),
                            );
                        },
                    }
                }
            }

            return null;
        }

        fn getCollectionsList(get_handle: *GetHandle, arena: mem.Allocator, collection: []const u8) ![]const u8 {
            var list_buf = std.ArrayList(u8).init(arena);
            defer list_buf.deinit();

            const get_pages = .{
                .stmt =
                \\SELECT slug, date, title
                \\FROM pages
                \\WHERE collection = ?
                \\ORDER BY date DESC, title ASC
                ,
                .type = struct {
                    slug: []const u8,
                    date: []const u8,
                    title: []const u8,
                },
            };

            var get_stmt = try get_handle.user_context.db.db.prepare(get_pages.stmt);
            defer get_stmt.deinit();

            var it = try get_stmt.iterator(
                get_pages.type,
                .{ .collection = collection },
            );

            try list_buf.appendSlice("<ul>");

            var num_items: u32 = 0;
            while (try it.nextAlloc(arena, .{})) |entry| {
                try list_buf.writer().print(
                    \\<li>
                    \\<a href="{[site_root]s}{[slug]s}">
                    \\{[date]s} {[title]s}
                    \\</a>
                    \\</li>
                ,
                    .{
                        .site_root = get_handle.user_context.site_root,
                        .slug = entry.slug,
                        .date = entry.date,
                        .title = entry.title,
                    },
                );

                num_items += 1;
            }

            if (num_items > 0) {
                try list_buf.appendSlice("</ul>");
                return try list_buf.toOwnedSlice();
            }

            return "";
        }

        fn getCollectionsLatest(get_handle: *GetHandle, arena: mem.Allocator, collection: []const u8) ![]const u8 {
            const get_page = .{
                .stmt =
                \\SELECT slug, title FROM pages WHERE collection = ?
                \\ORDER BY date DESC
                \\LIMIT 1
                ,
                .type = struct { slug: []const u8, title: []const u8 },
            };

            var get_stmt = try get_handle.user_context.db.db.prepare(get_page.stmt);
            defer get_stmt.deinit();

            const row = try get_stmt.oneAlloc(
                get_page.type,
                arena,
                .{},
                .{
                    .collection = collection,
                },
            ) orelse return error.EmptyCollection;

            // TODO is there a way to free this?
            //defer row.deinit();

            const value = try fmt.allocPrint(
                arena,
                \\<article>
                \\<a href="{s}{s}">{s}</a>
                \\</article>
            ,
                .{
                    get_handle.user_context.site_root,
                    row.slug,
                    row.title,
                },
            );
            errdefer arena.free(value);

            return value;
        }

        fn getMeta(get_handle: *GetHandle, arena: mem.Allocator) ![]const u8 {
            return try fmt.allocPrint(
                arena,
                \\<div class="field is-grouped is-grouped-multiline">
                \\<div class="control">
                \\<div class="tags has-addons">
                \\<span class="tag is-white">slug</span>
                \\<span class="tag is-light">{[slug]s}</span>
                \\</div>
                \\</div>
                \\
                \\<div class="control">
                \\<div class="tags has-addons">
                \\<span class="tag is-white">title</span>
                \\<span class="tag is-light">{[title]s}</span>
                \\</div>
                \\</div>
                \\</div>
            ,
                .{
                    .slug = get_handle.user_context.data.slug,
                    .title = if (@TypeOf(get_handle.user_context.data.title) == ?[]const u8)
                        get_handle.user_context.data.title.?
                    else
                        get_handle.user_context.data.title,
                },
            );
        }
    };
}

const UserError = enum(u8) {
    GetFailedForKey = 1,
    EmitFailed = 2,
    _,
};

fn MustacheWriterType(comptime UserContext: type) type {
    return struct {
        arena: mem.Allocator,
        context: GetHandle,
        writer: io.AnyWriter,
        /// When rendering components, a component may provide a CSS string
        /// that should be included on the page. We keep a hash map of
        /// component name to CSS string and then write them all
        /// once we process all of the content.
        style_buf: *std.StringHashMap([]const u8),
        /// When rendering components, a component may provide a script string
        /// that should be included on the page. We keep a hash map of
        /// component name to JS string and then write them all
        /// once we process all of the content.
        script_buf: *std.StringHashMap([]const u8),

        pub fn init(
            arena: mem.Allocator,
            user_context: UserContext,
            writer: io.AnyWriter,
        ) MustacheWriter {
            return .{
                .arena = arena,
                .context = .{ .user_context = user_context },
                .writer = writer,
                .style_buf = &user_context.component_assets.style_map,
                .script_buf = &user_context.component_assets.style_map,
            };
        }

        const MustacheWriter = @This();
        const GetHandle = GetHandleType(UserContext);

        pub const Error = error{ UnexpectedBehaviour, CouldNotRenderTemplate };

        pub fn write(ctx: *MustacheWriter, template: []const u8) Error!void {
            mustachMem(
                template,
                @ptrCast(ctx),
                &vtable,
            ) catch |err| {
                switch (err) {
                    error.UnexpectedBehaviour,
                    error.CouldNotRenderTemplate,
                    => |e| return e,
                }
            };
        }

        const vtable: c.mustach_itf = .{
            .emit = emit,
            .get = get,
            .enter = enter,
            .next = next,
            .leave = leave,
            .partial = partial,
        };

        fn emit(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, escaping: c_int, _: ?*c.FILE) callconv(.C) c_int {
            debug.assert(ptr != null);
            // Trying to emit a value we could not get?
            debug.assert(buf != null);

            Inner.emit(
                @ptrCast(@alignCast(ptr)),
                buf[0..len],
                if (escaping == 1) .escape else .raw,
            ) catch |err| {
                log.err("{any}", .{err});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.EmitFailed));
            };

            return 0;
        }

        // Calls the internal get implementation
        fn get(ptr: ?*anyopaque, buf: [*c]const u8, sbuf: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            const key = mem.sliceTo(buf, 0);

            const value = Inner.get(fromPtr(ptr), key) catch |err| {
                log.err("getInner {any}", .{err});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey));
            } orelse {
                log.err("get failed for key ({s})", .{key});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey));
            };

            sbuf.* = .{
                .value = @ptrCast(value),
                .length = value.len,
                .closure = null,
            };
            return 0;
        }

        fn enter(_: ?*anyopaque, buf: [*c]const u8) callconv(.C) c_int {
            const key = mem.sliceTo(buf, 0);
            _ = key;
            // return 1 if entered, or 0 if not entered
            // When 1 is returned, the function must activate the first item of the section
            return 1;
        }

        fn next(_: ?*anyopaque) callconv(.C) c_int {
            return 0;
        }

        fn leave(_: ?*anyopaque) callconv(.C) c_int {
            return 0;
        }

        fn partial(_: ?*anyopaque, _: [*c]const u8, _: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            return 0;
        }

        fn fromPtr(ptr: ?*anyopaque) *MustacheWriter {
            return @ptrCast(@alignCast(ptr));
        }

        const Inner = struct {
            /// Will write the contents of `buf` to an internal buffer.
            /// `emit_mode` determines whether the buf is written as-is or escaped.
            fn emit(self: *MustacheWriter, buf: []const u8, emit_mode: enum { raw, escape }) !void {
                switch (emit_mode) {
                    .raw => try self.writer.writeAll(buf),
                    .escape => {
                        for (buf) |char| {
                            switch (char) {
                                '<' => try self.writer.writeAll("&lt;"),
                                '>' => try self.writer.writeAll("&gt;"),
                                else => try self.writer.writeByte(char),
                            }
                        }
                    },
                }
            }

            const Getter = union(enum) {
                simple: *const fn (mem.Allocator, []const u8) anyerror!?[]const u8,
                ctx: *const fn (*MustacheWriter, []const u8) anyerror!?[]const u8,

                pub fn get(getter: Getter, ctx: *MustacheWriter, key: []const u8) !?[]const u8 {
                    return switch (getter) {
                        .simple => |simple_fn| simple_fn(ctx.arena, key),
                        .ctx => |ctx_fn| ctx_fn(ctx, key),
                    };
                }
            };

            const CollectionGetter = struct {
                pub fn getList(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    const collection = getBetween("collections.", ".list", k) orelse return null;
                    return try mw.context.getCollectionsList(mw.arena, collection);
                }
                pub fn getLatest(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    const name = getBetween("collections.", ".latest", k) orelse return null;
                    return try mw.context.getCollectionsLatest(mw.arena, name);
                }

                /// If `haystack` starts with prefix and ends with suffix, return the middle.
                fn getBetween(prefix: []const u8, suffix: []const u8, haystack: []const u8) ?[]const u8 {
                    return if (mem.startsWith(u8, haystack, prefix) and mem.endsWith(u8, haystack, suffix))
                        haystack[prefix.len .. haystack.len - suffix.len]
                    else
                        null;
                }
            };

            const LucideGetter = struct {
                pub fn getIcon(_: mem.Allocator, k: []const u8) !?[]const u8 {
                    return try getLucideIcon(k);
                }
            };

            const ContextGetter = struct {
                pub fn getKnown(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return try mw.context.getKnown(mw.arena, k);
                }
                pub fn getData(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return try mw.context.getData(mw.arena, k);
                }
            };

            const ComponentGetter = struct {
                pub fn getStyleRef(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return if (mem.eql(u8, k, "component.head"))
                        try fmt.allocPrint(
                            mw.arena,
                            \\<link rel="stylesheet" type="text/css" href="{[site_root]s}/component.css" />
                        ,
                            .{ .site_root = mw.context.user_context.site_root },
                        )
                    else
                        null;
                }

                pub fn getScriptRef(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return if (mem.eql(u8, k, "component.body"))
                        try fmt.allocPrint(
                            mw.arena,
                            \\<script src="{[site_root]s}/component.js"></script>
                        ,
                            .{ .site_root = mw.context.user_context.site_root },
                        )
                    else
                        null;
                }
            };

            fn get(ctx: *MustacheWriter, key: []const u8) !?[]const u8 {
                const getters: []const Getter = &.{
                    .{ .ctx = ContextGetter.getKnown },
                    .{ .ctx = ContextGetter.getData },
                    .{ .simple = LucideGetter.getIcon },
                    .{ .ctx = CollectionGetter.getList },
                    .{ .ctx = CollectionGetter.getLatest },
                    .{ .ctx = ComponentGetter.getStyleRef },
                    .{ .ctx = ComponentGetter.getScriptRef },
                };

                for (getters) |getter| {
                    if (try getter.get(ctx, key)) |value| {
                        return value;
                    }
                }

                if (mem.eql(u8, key, "meta")) {
                    return try ctx.context.getMeta(ctx.arena);
                }

                if (mem.eql(u8, key, "theme.head")) {
                    return if (ctx.context.user_context.site_root.len == 0)
                        try fmt.allocPrint(
                            ctx.arena,
                            \\<link rel="stylesheet" type="text/css" href="/bulma.css" />
                        ,
                            .{},
                        )
                    else
                        try fmt.allocPrint(
                            ctx.arena,
                            \\<link rel="stylesheet" type="text/css" href="{[site_root]s}/bulma.css" />
                        ,
                            .{ .site_root = ctx.context.user_context.site_root },
                        );
                } else if (mem.eql(u8, key, "theme.body")) {
                    // theme.body can be used by themes to inject e.g. scripts.
                    // It's currently empty, but content authors are still recommended
                    // to include it in their templates to allow a more seamless upgrade
                    // once themes do make use of it.

                    return try fmt.allocPrint(
                        ctx.arena,
                        \\<script src="{[site_root]s}/htmx.js"></script>
                    ,
                        .{ .site_root = ctx.context.user_context.site_root },
                    );
                }

                if (mem.startsWith(u8, key, "component ")) {
                    const component_src = src: {
                        var it = mem.tokenizeScalar(u8, key, ' ');

                        // skip component keyword
                        _ = it.next();

                        break :src it.rest();
                    };

                    var stmt = try ctx.context.user_context.db.db.prepare(
                        \\SELECT filepath FROM components WHERE name = ? LIMIT 1;
                        ,
                    );
                    defer stmt.deinit();

                    const row = try stmt.oneAlloc(
                        struct { filepath: []const u8 },
                        ctx.arena,
                        .{},
                        .{ .name = component_src },
                    ) orelse return error.MissingComponent;

                    var file = try fs.openFileAbsolute(row.filepath, .{});
                    defer file.close();

                    var script_buf = std.ArrayList(u8).init(ctx.arena);
                    defer script_buf.deinit();
                    try file.reader().readAllArrayList(&script_buf, math.maxInt(usize));
                    const script = try script_buf.toOwnedSliceSentinel(0);
                    defer ctx.arena.free(script);

                    log.debug(
                        "render component ({s}) at src {s}",
                        .{ component_src, row.filepath },
                    );

                    var buf = std.ArrayList(u8).init(ctx.arena);
                    errdefer buf.deinit();

                    renderComponent(
                        ctx.arena,
                        script,
                        buf.writer(),
                        ctx.style_buf,
                        ctx.script_buf,
                        .{
                            .site_root = ctx.context.user_context.site_root,
                        },
                    ) catch |err| {
                        log.err("Failure while rendering component: {any}", .{err});
                        return err;
                    };

                    if (buf.items.len == 0) {
                        log.err("Component ({s}) did not render.", .{component_src});
                        return error.ComponentMustRender;
                    }

                    return try buf.toOwnedSlice();
                }

                return null;
            }
        };
    };
}
fn mustachMem(template: []const u8, closure: ?*anyopaque, vtable: *const c.mustach_itf) !void {
    var result: [*c]const u8 = null;
    var result_len: usize = undefined;

    const return_val = c.mustach_mem(
        @ptrCast(template),
        template.len,
        vtable,
        closure,
        0,
        @ptrCast(&result),
        &result_len,
    );

    switch (return_val) {
        c.MUSTACH_OK => {
            // We provide our own emit callback so any result written
            // by mustach is undefined behaviour
            if (result_len != 0) return error.UnexpectedBehaviour;
            // We don't expect mustach to write anything to result, but it does
            // modify the address in result for some reason? In any case, here
            // we make sure that it's the empty string if it is set.
            if (result != null and result[0] != 0) return error.UnexpectedBehaviour;
        },
        c.MUSTACH_ERROR_SYSTEM,
        c.MUSTACH_ERROR_INVALID_ITF,
        c.MUSTACH_ERROR_UNEXPECTED_END,
        c.MUSTACH_ERROR_BAD_UNESCAPE_TAG,
        c.MUSTACH_ERROR_EMPTY_TAG,
        c.MUSTACH_ERROR_BAD_DELIMITER,
        c.MUSTACH_ERROR_TOO_DEEP,
        c.MUSTACH_ERROR_CLOSING,
        c.MUSTACH_ERROR_TOO_MUCH_NESTING,
        => |err| {
            log.debug("Uh oh! Error {any}\n", .{err});
            return error.CouldNotRenderTemplate;
        },
        c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey)) => {
            return error.CouldNotRenderTemplate;
        },
        // We've handled all other known mustach return codes
        else => {
            log.debug("{d}", .{return_val});
            unreachable;
        },
    }
}

fn getLucideIcon(key: []const u8) !?[]const u8 {
    if (mem.startsWith(u8, key, "lucide.")) {
        return lucide.icon(key["lucide.".len..]);
    }

    return null;
}

fn handleException(ctx: *c.JSContext) !noreturn {
    const exception = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exception);

    const str = c.JS_ToCString(ctx, exception);
    defer c.JS_FreeCString(ctx, str);
    const error_message = mem.span(str);

    const stack = c.JS_GetPropertyStr(ctx, exception, "stack");
    defer c.JS_FreeValue(ctx, stack);

    const stack_str = c.JS_ToCString(ctx, stack);
    defer c.JS_FreeCString(ctx, stack_str);
    const stack_message = mem.span(stack_str);

    log.err("JS Exception: {s} {s}", .{ error_message, stack_message });

    return error.JSException;
}

const RenderComponentModel = struct {
    site_root: []const u8,
};

/// renderComponent will spin up a one-off QuickJS runtime and register some modules in a brand new context:
/// - htm
/// - vhtml
/// Then, it will load and execute the component source as a module, expecting it to export the following:
/// - render(): string
/// - style?: string
/// The render function will be called to produce the component html.
/// The style string, if present, will be stored in a hash map, keyed by the component source.
///
/// NOTE: renderComponent MUST write to the writer.
fn renderComponent(allocator: mem.Allocator, src: [:0]const u8, writer: anytype, style_buf: *std.StringHashMap([]const u8), script_buf: *std.StringHashMap([]const u8), model: RenderComponentModel) !void {
    const rt = c.JS_NewRuntime() orelse return error.CannotAllocateJSRuntime;
    defer c.JS_FreeRuntime(rt);
    c.JS_SetMemoryLimit(rt, 0x100000);
    c.JS_SetMaxStackSize(rt, 0x100000);

    const ctx = c.JS_NewContext(rt) orelse return error.CannotAllocateJSContext;
    defer c.JS_FreeContext(ctx);

    // TODO register htm.js as a module so the script can do
    // import htm from 'htm';
    // function h(type, props, ...children) { return { type, props, children }; }
    // const t = htm.bind(h);
    //
    // const html = t`<h1>Hello world</h1>`;

    // m = js_new_module_def(ctx, module_name_atom);
    // The module source is treated as the contents of an async function body, but return is not allowed.

    const htm_mod = c.JS_Eval(ctx, htm.mjs, htm.mjs.len, "htm", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, htm_mod);
    switch (htm_mod.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const vhtml_mod = c.JS_Eval(ctx, vhtml.js, vhtml.js.len, "vhtml", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, vhtml_mod);
    switch (vhtml_mod.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const hacky_mod_src: [:0]const u8 = try fmt.allocPrintZ(allocator, "export const site_root = \"{[site_root]s}\";", .{ .site_root = model.site_root });
    defer allocator.free(hacky_mod_src);
    const hacky_mod = c.JS_Eval(ctx, hacky_mod_src, hacky_mod_src.len, "site", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, hacky_mod);

    const hacky_mod_src2: [:0]const u8 =
        \\import htm from 'htm';
        \\export const html = htm.bind(globalThis.vhtml);
    ;
    const hacky_mod2 = c.JS_Eval(ctx, hacky_mod_src2, hacky_mod_src2.len, "goku", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, hacky_mod2);

    const user_component_mod = c.JS_Eval(ctx, src, src.len, "component", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, user_component_mod);
    switch (user_component_mod.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const t =
        \\import * as c from 'component';
        \\try {
        \\globalThis.html = c.render();
        \\} catch (e) {
        \\globalThis.html = e.message || 'Failed to render the component.';
        \\}
        \\if (c.style) globalThis.style = c.style;
        \\if (c.script) globalThis.script = c.script;
    ;
    const eval_result = c.JS_Eval(ctx, t, t.len, "<input>", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, eval_result);
    switch (eval_result.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const global_object = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global_object);

    {
        const html = c.JS_GetPropertyStr(ctx, global_object, "html");
        defer c.JS_FreeValue(ctx, html);

        switch (html.tag) {
            c.JS_TAG_EXCEPTION => try handleException(ctx),
            else => return error.Huh,
            c.JS_TAG_STRING => {
                const str = c.JS_ToCString(ctx, html);
                defer c.JS_FreeCString(ctx, str);

                // I need to be able to use certain shortcodes from within the rendered html.
                // Ideally, I provide a js module or the like with certain constants or access
                // to site attributes.
                var string_replacement_hack = std.ArrayList(u8).init(allocator);
                defer string_replacement_hack.deinit();
                try writer.print("{s}", .{str});
            },
        }
    }

    {
        const style = c.JS_GetPropertyStr(ctx, global_object, "style");
        defer c.JS_FreeValue(ctx, style);
        log.info("style here? {d}", .{style.tag});
        switch (style.tag) {
            c.JS_TAG_EXCEPTION => try handleException(ctx),
            c.JS_TAG_STRING => {
                log.debug("Gonna try to see if there's a style for the src", .{});
                log.debug("[[{s}]]", .{src});
                const x = style_buf.get(src);
                if (x) |existing| {
                    _ = existing;
                    log.debug("Found existing!", .{});
                    //if (true) @panic("boop");
                } else {
                    log.debug("Didn't find existing", .{});
                    //if (true) @panic("boop");
                }
                if (true) {
                    const result = try style_buf.getOrPut(src);
                    if (!result.found_existing) {
                        const str = c.JS_ToCString(ctx, style);
                        defer c.JS_FreeCString(ctx, str);
                        log.info("[[{s}]]", .{str});
                        // TODO find better way of persisting these strings beyond page build
                        result.value_ptr.* = try style_buf.allocator.dupe(u8, mem.span(str));
                    }
                }
            },
            else => {},
        }
    }

    {
        const script = c.JS_GetPropertyStr(ctx, global_object, "script");
        defer c.JS_FreeValue(ctx, script);
        log.info("script here? {d}", .{script.tag});
        switch (script.tag) {
            c.JS_TAG_EXCEPTION => try handleException(ctx),
            c.JS_TAG_STRING => {
                const result = try script_buf.getOrPut(src);
                if (!result.found_existing) {
                    const str = c.JS_ToCString(ctx, script);
                    defer c.JS_FreeCString(ctx, str);
                    log.info("JS! {s}", .{str});
                    // TODO find better way of persisting these strings beyond page build
                    result.value_ptr.* = try script_buf.allocator.dupe(u8, mem.span(str));
                }
            },
            else => {},
        }
    }
}
