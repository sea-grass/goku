const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const log = std.log.scoped(.mustache);
const lucide = @import("lucide");
const mem = std.mem;
const std = @import("std");
const Database = @import("Database.zig");

pub fn Mustache(comptime Context: type) type {
    return struct {
        pub const Self = @This();

        pub fn renderStream(allocator: mem.Allocator, template: []const u8, db: *Database, context: Context, writer: anytype) !void {
            var arena = heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var x: RenderContext(Context, @TypeOf(writer)) = .{
                .arena = arena.allocator(),
                .context = context,
                .db = db,
                .writer = writer,
            };

            try x.renderLeaky(template);
        }
    };
}

fn RenderContext(comptime Context: type, comptime Writer: type) type {
    return struct {
        arena: mem.Allocator,
        context: Context,
        db: *Database,
        writer: Writer,

        const vtable: c.mini_mustach_itf = .{
            .emit = emit,
            .get = get,
            .enter = enter,
            .next = next,
            .leave = leave,
            .partial = partial,
        };

        const Self = @This();

        pub fn renderLeaky(self: *Self, template: []const u8) !void {
            switch (c.mini_mustach(
                @ptrCast(template),
                template.len,
                &Self.vtable,
                self,
            )) {
                c.MUSTACH_OK => {},
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
                else => |value| {
                    log.debug("Received unknown value {d}\n", .{value});
                    unreachable;
                },
            }
        }

        fn emit(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, escaping: c_int) callconv(.C) c_int {
            debug.assert(ptr != null);
            // Trying to emit a value we could not get?
            debug.assert(buf != null);

            const ctx: *Self = @ptrCast(@alignCast(ptr));

            if (escaping == 1) {
                var escaped = std.ArrayList(u8).init(ctx.arena);
                defer escaped.deinit();

                for (buf[0..len]) |char| {
                    switch (char) {
                        '<' => escaped.appendSlice("&lt;") catch return -1,
                        '>' => escaped.appendSlice("&gt;") catch return -1,
                        else => escaped.append(char) catch return -1,
                    }
                }

                ctx.writer.writeAll(escaped.items) catch return -1;
            } else {
                ctx.writer.writeAll(buf[0..len]) catch return -1;
            }

            return 0;
        }

        fn get(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, sbuf: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            _get(
                @ptrCast(@alignCast(ptr)),
                buf[0..len],
                sbuf,
            ) catch {
                log.err("get failed for key ({s})", .{buf[0..len]});
                return -1;
            };

            return 0;
        }

        fn _get(ctx: *Self, key: []const u8, sbuf: [*c]c.struct_mustach_sbuf) !void {
            if (mem.eql(u8, key, "content")) {
                if (!@hasField(@TypeOf(ctx.context), "content")) {
                    return error.ContextIsMissingContent;
                }

                const value = try ctx.arena.dupeZ(u8, ctx.context.content);
                sbuf.* = .{
                    .value = value,
                    .length = value.len,
                    .closure = null,
                };
                return;
            } else if (mem.eql(u8, key, "site_root")) {
                if (!@hasField(@TypeOf(ctx.context), "site_root")) {
                    return error.ContextIsMissingSiteRoot;
                }

                const value = try ctx.arena.dupeZ(u8, ctx.context.site_root);
                sbuf.* = .{
                    .value = value,
                    .length = value.len,
                    .closure = null,
                };
                return;
            }

            inline for (@typeInfo(@TypeOf(ctx.context.data)).Struct.fields) |f| {
                if (mem.eql(u8, key, f.name)) {
                    switch (@typeInfo(f.type)) {
                        .Optional => {
                            const value = @field(ctx.context.data, f.name);
                            // TODO should a missing optional value be an error?
                            // I'm tempted to just make it ""
                            if (value == null) {
                                sbuf.* = .{ .value = "", .length = 0, .closure = null };
                                return;
                            }

                            sbuf.* = .{
                                .value = try ctx.arena.dupeZ(u8, value.?),
                                .length = value.?.len,
                                .closure = null,
                            };
                            return;
                        },
                        .Bool => {
                            const str = if (@field(ctx.context.data, f.name)) "true" else "false";

                            sbuf.* = .{
                                .value = try ctx.arena.dupeZ(u8, str),
                                .length = str.len,
                                .closure = null,
                            };
                            return;
                        },
                        else => {
                            const value = @field(ctx.context.data, f.name);
                            sbuf.* = .{
                                .value = try ctx.arena.dupeZ(u8, value),
                                .length = value.len,
                                .closure = null,
                            };
                            return;
                        },
                    }
                }
            }

            if (mem.startsWith(u8, key, "lucide.")) {
                const icon_name = key["lucide.".len..];
                const icon = lucide.icon(icon_name);
                sbuf.* = .{
                    .value = @ptrCast(icon),
                    .length = icon.len,
                    .closure = null,
                };
                return;
            }

            if (mem.startsWith(u8, key, "collections.")) {
                if (mem.endsWith(u8, key, ".list")) {
                    const collection = key["collections.".len .. key.len - ".list".len];

                    // get db it for pages in collection
                    //
                    var list_buf = std.ArrayList(u8).init(ctx.arena);
                    defer list_buf.deinit();

                    const get_pages =
                        \\SELECT slug, title FROM pages WHERE collection = ?
                        \\ORDER BY date DESC, title ASC
                    ;

                    var get_stmt = try ctx.db.db.prepare(get_pages);
                    defer get_stmt.deinit();

                    var it = try get_stmt.iterator(
                        struct { slug: []const u8, title: []const u8 },
                        .{
                            .collection = collection,
                        },
                    );

                    var arena = heap.ArenaAllocator.init(ctx.arena);
                    defer arena.deinit();

                    try list_buf.appendSlice("<ul>");

                    var num_items: u32 = 0;
                    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
                        try list_buf.writer().print(
                            \\<li><a href="{s}{s}">{s}</a></li>
                        ,
                            .{ ctx.context.site_root, entry.slug, entry.title },
                        );

                        num_items += 1;
                    }

                    if (num_items > 0) {
                        try list_buf.appendSlice("</ul>");
                        const value = try list_buf.toOwnedSlice();
                        sbuf.* = .{
                            .value = @ptrCast(value),
                            .length = value.len,
                            .closure = null,
                        };
                    } else {
                        sbuf.* = .{
                            .value = "",
                            .length = 0,
                            .closure = null,
                        };
                    }

                    return;
                } else if (mem.endsWith(u8, key, ".latest")) {
                    const collection = key["collections.".len .. key.len - ".latest".len];

                    const get_page =
                        \\SELECT slug, title FROM pages WHERE collection = ?
                        \\ORDER BY date DESC
                        \\LIMIT 1
                    ;

                    var get_stmt = try ctx.db.db.prepare(get_page);
                    defer get_stmt.deinit();

                    const row = try get_stmt.oneAlloc(
                        struct { slug: []const u8, title: []const u8 },
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

                    sbuf.* = .{
                        .value = @ptrCast(value),
                        .length = value.len,
                        .closure = null,
                    };

                    return;
                }
            }

            if (mem.eql(u8, key, "meta")) {
                var arena = heap.ArenaAllocator.init(ctx.arena);
                defer arena.deinit();

                const value = try fmt.allocPrint(
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
                errdefer ctx.arena.free(value);

                sbuf.* = .{
                    .value = @ptrCast(value),
                    .length = value.len,
                    .closure = null,
                };

                return;
            }

            return error.KeyNotFound;
        }

        fn enter(_: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.C) c_int {
            log.debug("enter\n", .{});
            return 0;
        }

        fn next(_: ?*anyopaque) callconv(.C) c_int {
            log.debug("next\n", .{});
            return 0;
        }

        fn leave(_: ?*anyopaque) callconv(.C) c_int {
            log.debug("leave\n", .{});
            return 0;
        }

        fn partial(_: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            log.debug("partial\n", .{});
            return 0;
        }
    };
}
