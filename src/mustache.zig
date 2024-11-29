const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.mustache);
const lucide = @import("lucide");
const mem = std.mem;
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;

pub fn renderStream(allocator: mem.Allocator, template: []const u8, context: anytype, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mustache_writer: MustacheWriterType(
        @TypeOf(context),
    ) = .{
        .arena = arena.allocator(),
        .context = context,
        .writer = writer.any(),
    };

    try mustache_writer.write(template);
}

test renderStream {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

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
    );

    try testing.expectEqualStrings("foo", buf.items);
}

fn MustacheWriterType(comptime Context: type) type {
    return struct {
        arena: mem.Allocator,
        context: Context,
        writer: io.AnyWriter,

        const MustacheWriter = @This();

        const UserError = enum(u8) {
            GetFailedForKey = 1,
            EmitFailed = 2,
            _,
        };

        pub const Error = error{ UnexpectedBehaviour, CouldNotRenderTemplate };

        const vtable: c.mustach_itf = .{
            .emit = emit,
            .get = get,
            .enter = enter,
            .next = next,
            .leave = leave,
            .partial = partial,
        };

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

        fn emit(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, escaping: c_int, _: ?*c.FILE) callconv(.C) c_int {
            debug.assert(ptr != null);
            // Trying to emit a value we could not get?
            debug.assert(buf != null);

            emitInner(
                @ptrCast(@alignCast(ptr)),
                buf[0..len],
                if (escaping == 1) .escape else .raw,
            ) catch |err| {
                log.err("{any}", .{err});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.EmitFailed));
            };

            return 0;
        }

        /// Will write the contents of `buf` to an internal buffer.
        /// `emit_mode` determines whether the buf is written as-is or escaped.
        fn emitInner(self: *MustacheWriter, buf: []const u8, emit_mode: enum { raw, escape }) !void {
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

        // Calls the internal get implementation
        fn get(ptr: ?*anyopaque, buf: [*c]const u8, sbuf: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            const key = mem.sliceTo(buf, 0);

            if (getInner(
                fromPtr(ptr),
                key,
            ) catch null) |value| {
                sbuf.* = .{
                    .value = @ptrCast(value),
                    .length = value.len,
                    .closure = null,
                };

                return 0;
            }

            log.err("get failed for key ({s})", .{key});
            return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey));
        }

        fn getInner(ctx: *MustacheWriter, key: []const u8) !?[]const u8 {
            if (try getKnownFromContext(ctx.arena, &ctx.context, key)) |value| {
                return value;
            }

            if (try getFromContextData(ctx.arena, &ctx.context, key)) |value| {
                return value;
            }

            if (try getLucideIcon(key)) |value| {
                return value;
            }

            if (mem.startsWith(u8, key, "collections.") and
                mem.endsWith(u8, key, ".list"))
            {
                const collection = key["collections.".len .. key.len - ".list".len];
                return try getCollectionsList(ctx.arena, &ctx.context, collection);
            }

            if (mem.startsWith(u8, key, "collections.") and
                mem.endsWith(u8, key, ".latest"))
            {
                const collection = key["collections.".len .. key.len - ".latest".len];
                return try getCollectionsLatest(ctx.arena, &ctx.context, collection);
            }

            if (mem.eql(u8, key, "meta")) {
                return try getMeta(ctx.arena, &ctx.context);
            }

            if (mem.eql(u8, key, "theme.head")) {
                return if (ctx.context.site_root.len == 0)
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
                        .{ .site_root = ctx.context.site_root },
                    );
            } else if (mem.eql(u8, key, "theme.body")) {
                // theme.body can be used by themes to inject e.g. scripts.
                // It's currently empty, but content authors are still recommended
                // to include it in their templates to allow a more seamless upgrade
                // once themes do make use of it.

                return "";
            }

            return null;
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

        fn getKnownFromContext(arena: mem.Allocator, context: *const Context, key: []const u8) !?[]const u8 {

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
                    if (!@hasField(Context, context_key)) return error.ContextMissingRequestedKey;

                    return try arena.dupeZ(u8, @field(context, context_key));
                }
            }

            return null;
        }

        fn getFromContextData(arena: mem.Allocator, context: *const Context, key: []const u8) !?[]const u8 {
            inline for (@typeInfo(@TypeOf(context.data)).@"struct".fields) |f| {
                if (mem.eql(u8, key, f.name)) {
                    switch (@typeInfo(f.type)) {
                        .optional => {
                            const value = @field(context.data, f.name);

                            if (value) |v| {
                                return try arena.dupeZ(u8, v);
                            }

                            return "";
                        },
                        .bool => {
                            return if (@field(context.data, f.name)) "true" else "false";
                        },
                        else => {
                            return try arena.dupeZ(
                                u8,
                                @field(context.data, f.name),
                            );
                        },
                    }
                }
            }

            return null;
        }

        fn getCollectionsList(arena: mem.Allocator, context: *const Context, collection: []const u8) ![]const u8 {
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

            var get_stmt = try context.db.db.prepare(get_pages.stmt);
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
                        .site_root = context.site_root,
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
            } else {
                return "";
            }
        }

        fn getCollectionsLatest(arena: mem.Allocator, context: *Context, collection: []const u8) ![]const u8 {
            const get_page = .{
                .stmt =
                \\SELECT slug, title FROM pages WHERE collection = ?
                \\ORDER BY date DESC
                \\LIMIT 1
                ,
                .type = struct { slug: []const u8, title: []const u8 },
            };

            var get_stmt = try context.db.db.prepare(get_page.stmt);
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
                    context.site_root,
                    row.slug,
                    row.title,
                },
            );
            errdefer arena.free(value);

            return value;
        }

        fn getMeta(arena: mem.Allocator, context: *Context) ![]const u8 {
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
                    .slug = context.data.slug,
                    .title = if (@TypeOf(context.data.title) == ?[]const u8) context.data.title.? else context.data.title,
                },
            );
        }

        fn fromPtr(ptr: ?*anyopaque) *MustacheWriter {
            return @ptrCast(@alignCast(ptr));
        }
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
        // We've handled all other known mustach return codes
        else => unreachable,
    }
}

fn getLucideIcon(key: []const u8) !?[]const u8 {
    if (mem.startsWith(u8, key, "lucide.")) {
        return lucide.icon(key["lucide.".len..]);
    }

    return null;
}
