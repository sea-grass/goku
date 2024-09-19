const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
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

            try renderLeaky(
                arena.allocator(),
                template,
                context,
                db,
                writer,
            );
        }

        fn renderLeaky(arena: mem.Allocator, template: []const u8, context: Context, db: *Database, writer: anytype) !void {
            var render_context: RenderContext(Context, @TypeOf(writer)) = .{
                .arena = arena,
                .context = context,
                .db = db,
                .writer = writer,
            };
            try render_context.renderLeaky(template);
        }
    };
}

fn RenderContext(comptime Context: type, comptime Writer: type) type {
    return struct {
        arena: mem.Allocator,
        context: Context,
        db: *Database,
        writer: Writer,

        const vtable: c.mustach_itf = .{
            .emit = emit,
            .get = get,
            .enter = enter,
            .next = next,
            .leave = leave,
            .partial = partial,
        };

        const Self = @This();

        pub fn renderLeaky(self: *Self, template: []const u8) !void {
            var result: [*c]const u8 = null;
            var result_len: usize = undefined;

            switch (c.mustach_mem(
                @ptrCast(template),
                template.len,
                &Self.vtable,
                self,
                0,
                @ptrCast(&result),
                &result_len,
            )) {
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
                else => |value| {
                    log.debug("Received unknown value {d}\n", .{value});
                    unreachable;
                },
            }
        }

        fn emit(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, escaping: c_int, _: [*c]c.FILE) callconv(.C) c_int {
            log.debug("emit", .{});
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

        fn get(ptr: ?*anyopaque, buf: [*c]const u8, sbuf: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            const key = mem.sliceTo(buf, 0);
            log.debug("get({s})", .{key});
            _get(
                @ptrCast(@alignCast(ptr)),
                key,
                sbuf,
            ) catch {
                log.err("get failed for key ({s})", .{key});
                return -1;
            };

            return 0;
        }

        fn _get(ctx: *Self, key: []const u8, sbuf: [*c]c.struct_mustach_sbuf) !void {
            // Need to implement some sort of a stack context system here.
            // If someone "enters" then I need some way of reaching further into the
            // context. Something like
            // reachInto(ctx.context.data, .{ "path", "to", "value" });
            // ...that I can then use like
            // reachInto(ctx.context.data, stack.items);
            // ...where stack is an ArrayList([]const u8).
            // reachInto might look like
            // fn reachInto(data: anytype, path: []const []const u8) ??? {
            //   if (path.len == 0) return data;
            //   if (path.len == 1) {
            //      inline for (@typeInfo(@TypeOf(data)).Struct.fields) |f| {
            //          if (mem.eql(u8, f.name, path[0])) {
            //            return @field(data, f.name);
            //          }
            //      }
            //      return error.CouldNotFindField;
            //  }
            //  return reachInto(
            //      reachInto(data, path[0..1]),
            //      path[1..],
            //  );
            // }
            // ...The problem being that I don't know how to specify the return type of the fn
            // And I'm not sure at call time that I'll have that information?
            // The problem: The mustache syntax to enter a named section can work for a regular value,
            // a struct, or an array, but....,......hm
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

        fn enter(_: ?*anyopaque, buf: [*c]const u8) callconv(.C) c_int {
            const key = mem.sliceTo(buf, 0);
            log.debug("enter({s})", .{key});
            // return 1 if entered, or 0 if not entered
            // When 1 is returned, the function must activate the first item of the section
            return 1;
        }

        fn next(_: ?*anyopaque) callconv(.C) c_int {
            log.debug("next", .{});
            return 0;
        }

        fn leave(_: ?*anyopaque) callconv(.C) c_int {
            log.debug("leave", .{});
            return 0;
        }

        fn partial(_: ?*anyopaque, _: [*c]const u8, _: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
            log.debug("partial", .{});
            return 0;
        }
    };
}
