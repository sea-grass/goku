const c = @import("c");
const debug = std.debug;
const heap = std.heap;
const log = std.log.scoped(.mustache);
const lucide = @import("lucide");
const mem = std.mem;
const std = @import("std");

pub fn Mustache(comptime Context: type) type {
    return struct {
        pub const Self = @This();

        pub fn renderStream(allocator: mem.Allocator, template: []const u8, context: Context, writer: anytype) !void {
            var arena = heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var x: RenderContext(Context, @TypeOf(writer)) = .{
                .arena = arena.allocator(),
                .context = context,
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
            const ctx: *Self = @ptrCast(@alignCast(ptr));

            const key = buf[0..len];
            inline for (@typeInfo(Context).Struct.fields) |f| {
                if (mem.eql(u8, key, f.name)) {
                    switch (@typeInfo(f.type)) {
                        .Optional => {
                            const value = @field(ctx.context, f.name);
                            sbuf.* = .{
                                .value = ctx.arena.dupeZ(u8, value.?) catch return -1,
                                .length = value.?.len,
                                .closure = null,
                            };
                            return 0;
                        },
                        .Bool => {
                            const str = if (@field(ctx.context, f.name)) "true" else "false";

                            sbuf.* = .{
                                .value = ctx.arena.dupeZ(u8, str) catch return -1,
                                .length = str.len,
                                .closure = null,
                            };
                            return 0;
                        },
                        else => {
                            const value = @field(ctx.context, f.name);
                            sbuf.* = .{
                                .value = ctx.arena.dupeZ(u8, value) catch return -1,
                                .length = value.len,
                                .closure = null,
                            };
                            return 0;
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
                return 0;
            }

            return -1;
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
