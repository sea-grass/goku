const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const log = std.log.scoped(.mustache);
const lucide = @import("lucide");
const mem = std.mem;
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;

pub fn renderStream(allocator: mem.Allocator, template: []const u8, context: anytype, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const MustacheWriter = MustacheWriterType(@TypeOf(context), @TypeOf(writer));
    var mustache_writer: MustacheWriter = .{
        .arena = arena.allocator(),
        .context = context,
        .writer = writer,
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

fn MustacheWriterType(comptime Context: type, comptime Writer: type) type {
    return struct {
        arena: mem.Allocator,
        context: Context,
        writer: Writer,

        const vtable: c.mustach_itf = .{
            .emit = emit,
            .get = get,
            .enter = enter,
            .next = next,
            .leave = leave,
            .partial = partial,
        };

        const WriteError = error{ UnexpectedBehaviour, CouldNotRenderTemplate };
        pub fn write(ctx: *Self, template: []const u8) WriteError!void {
            var result: [*c]const u8 = null;
            var result_len: usize = undefined;

            const return_val = c.mustach_mem(
                @ptrCast(template),
                template.len,
                &vtable,
                ctx,
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

        const Self = @This();

        fn getKnownFromContext(self: *Self, key: []const u8) !?[]const u8 {

            // These are known goku constants that are expected to be available during page rendering.
            const context_keys = &.{ "content", "site_root" };

            // At runtime, if a template tries to get one of these keys, we look for it in Context.
            // If the key is found, we populate the buf with a copy.
            // Otherwise, we return a runtime error.
            inline for (context_keys) |context_key| {
                if (mem.eql(u8, key, context_key)) {
                    if (!@hasField(Context, context_key)) return error.ContextMissingRequestedKey;

                    return try self.arena.dupeZ(u8, @field(self.context, context_key));
                }
            }

            return null;
        }

        fn getFromContextData(self: *Self, key: []const u8) !?[]const u8 {
            inline for (@typeInfo(@TypeOf(self.context.data)).@"struct".fields) |f| {
                if (mem.eql(u8, key, f.name)) {
                    switch (@typeInfo(f.type)) {
                        .optional => {
                            const value = @field(self.context.data, f.name);

                            if (value) |v| {
                                return try self.arena.dupeZ(u8, v);
                            }

                            return "";
                        },
                        .bool => {
                            return if (@field(self.context.data, f.name)) "true" else "false";
                        },
                        else => {
                            return try self.arena.dupeZ(
                                u8,
                                @field(self.context.data, f.name),
                            );
                        },
                    }
                }
            }

            return null;
        }

        fn getLucideIcon(_: *Self, key: []const u8) !?[]const u8 {
            if (mem.startsWith(u8, key, "lucide.")) {
                return lucide.icon(key["lucide.".len..]);
            }

            return null;
        }

        fn gget(ctx: *Self, key: []const u8) !?[]const u8 {
            if (try ctx.getKnownFromContext(key)) |value| {
                return value;
            }

            if (try ctx.getFromContextData(key)) |value| {
                return value;
            }

            if (try ctx.getLucideIcon(key)) |value| {
                return value;
            }

            if (mem.startsWith(u8, key, "collections.")) {
                if (mem.endsWith(u8, key, ".list")) {
                    const collection = key["collections.".len .. key.len - ".list".len];

                    // get db it for pages in collection
                    //
                    var list_buf = std.ArrayList(u8).init(ctx.arena);
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

                    var get_stmt = try ctx.context.db.db.prepare(get_pages.stmt);
                    defer get_stmt.deinit();

                    var it = try get_stmt.iterator(
                        get_pages.type,
                        .{ .collection = collection },
                    );

                    var arena = heap.ArenaAllocator.init(ctx.arena);
                    defer arena.deinit();

                    try list_buf.appendSlice("<ul>");

                    var num_items: u32 = 0;
                    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
                        try list_buf.writer().print(
                            \\<li>
                            \\<a href="{[site_root]s}{[slug]s}">
                            \\{[date]s} {[title]s}
                            \\</a>
                            \\</li>
                        ,
                            .{
                                .site_root = ctx.context.site_root,
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
                } else if (mem.endsWith(u8, key, ".latest")) {
                    const collection = key["collections.".len .. key.len - ".latest".len];

                    const get_page = .{
                        .stmt =
                        \\SELECT slug, title FROM pages WHERE collection = ?
                        \\ORDER BY date DESC
                        \\LIMIT 1
                        ,
                        .type = struct { slug: []const u8, title: []const u8 },
                    };

                    var get_stmt = try ctx.context.db.db.prepare(get_page.stmt);
                    defer get_stmt.deinit();

                    const row = try get_stmt.oneAlloc(
                        get_page.type,
                        ctx.arena,
                        .{},
                        .{
                            .collection = collection,
                        },
                    ) orelse return error.EmptyCollection;

                    // TODO is there a way to free this?
                    //defer row.deinit();

                    var arena = heap.ArenaAllocator.init(ctx.arena);
                    defer arena.deinit();

                    const value = try fmt.allocPrint(
                        ctx.arena,
                        \\<article>
                        \\<a href="{s}{s}">{s}</a>
                        \\</article>
                    ,
                        .{
                            ctx.context.site_root,
                            row.slug,
                            row.title,
                        },
                    );
                    errdefer ctx.arena.free(value);

                    return value;
                }
            }

            if (mem.eql(u8, key, "meta")) {
                return try fmt.allocPrint(
                    ctx.arena,
                    \\<div class="field is-grouped is-grouped-multiline">
                    \\<div class="control">
                    \\<div class="tags has-addons">
                    \\<span class="tag is-white">slug</span>
                    \\<span class="tag is-light">{s}</span>
                    \\</div>
                    \\</div>
                    \\
                    \\<div class="control">
                    \\<div class="tags has-addons">
                    \\<span class="tag is-white">title</span>
                    \\<span class="tag is-light">{s}</span>
                    \\</div>
                    \\</div>
                    \\</div>
                ,
                    .{
                        ctx.context.data.slug,
                        if (@TypeOf(ctx.context.data.title) == ?[]const u8) ctx.context.data.title.? else ctx.context.data.title,
                    },
                );
            }

            if (mem.eql(u8, key, "theme.head")) {
                return try fmt.allocPrint(
                    ctx.arena,
                    \\<link rel="stylesheet" type="text/css" href="/bulma.css" />
                ,
                    .{},
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

        // Will write the contents of `buf` to an internal buffer.
        // If `is_escaped` is true, it will escape the contents as
        // it streams them.
        fn eemit(self: *Self, buf: []const u8, is_escaped: bool) !void {
            if (is_escaped) {
                var escaped = std.ArrayList(u8).init(self.arena);
                defer escaped.deinit();
                for (buf) |char| {
                    switch (char) {
                        '<' => try escaped.appendSlice("&lt;"),
                        '>' => try escaped.appendSlice("&gt;"),
                        else => try escaped.append(char),
                    }
                }

                try self.writer.writeAll(escaped.items);
            } else {
                try self.writer.writeAll(buf);
            }
        }

        // Calls the internal emit implementation
        fn emit(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, escaping: c_int, _: ?*c.FILE) callconv(.C) c_int {
            debug.assert(ptr != null);
            // Trying to emit a value we could not get?
            debug.assert(buf != null);

            eemit(
                @ptrCast(@alignCast(ptr)),
                buf[0..len],
                escaping == 1,
            ) catch |err| {
                log.err("{any}", .{err});
                return -1;
            };

            return 0;
        }

        // Calls the internal get implementation
        fn get(ptr: ?*anyopaque, buf: [*c]const u8, sbuf: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            const key = mem.sliceTo(buf, 0);

            const result = gget(
                @ptrCast(@alignCast(ptr)),
                key,
            ) catch null;

            if (result) |value| {
                sbuf.* = .{
                    .value = @ptrCast(value),
                    .length = value.len,
                    .closure = null,
                };
                return 0;
            }

            log.err("get failed for key ({s})", .{key});
            return -1;
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
    };
}
