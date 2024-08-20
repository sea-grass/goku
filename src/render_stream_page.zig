const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const mem = std.mem;
const lucide = @import("lucide");
const Markdown = @import("Markdown.zig");
const Page = @import("page.zig").Page;
const PageData = @import("PageData.zig");
const c = @import("c");

const tmpl = @embedFile("templates/basic.html");

// Write `page` as an html document to the `writer`.
pub fn renderStreamPage(allocator: mem.Allocator, page: Page, writer: anytype) !void {
    const data = try PageData.fromYamlString(
        allocator,
        @ptrCast(page.markdown.frontmatter),
        page.markdown.frontmatter.len,
    );
    defer data.deinit(allocator);

    try Parser(@TypeOf(writer)).parse(allocator, page, writer);
}

fn Parser(comptime Writer: type) type {
    return struct {
        writer: Writer,
        page: Page,
        arena: mem.Allocator,

        const Self = @This();

        pub const vtable: c.mini_mustach_itf = .{
            .emit = struct {
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
            }.emit,
            .get = struct {
                fn get(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, sbuf: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
                    const ctx: *Self = @ptrCast(@alignCast(ptr));

                    const key = buf[0..len];
                    if (mem.eql(u8, key, "title")) {
                        // TODO lookup title
                        const fallback_title = "(missing title)";
                        sbuf.* = .{
                            .value = ctx.arena.dupeZ(u8, fallback_title) catch return -1,
                            .length = fallback_title.len,
                            .closure = null,
                        };
                        return 0;
                    } else if (mem.eql(u8, key, "content")) {
                        const content = ctx.arena.dupeZ(u8, "content") catch return -1;

                        sbuf.* = .{
                            .value = content,
                            .length = content.len,
                            .closure = null,
                        };
                        return 0;
                    } else if (mem.startsWith(u8, key, "lucide.")) {
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
            }.get,
            .enter = struct {
                fn enter(_: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.C) c_int {
                    debug.print("enter\n", .{});
                    return 0;
                }
            }.enter,
            .next = struct {
                fn next(_: ?*anyopaque) callconv(.C) c_int {
                    debug.print("next\n", .{});
                    return 0;
                }
            }.next,
            .leave = struct {
                fn leave(_: ?*anyopaque) callconv(.C) c_int {
                    debug.print("leave\n", .{});
                    return 0;
                }
            }.leave,
            .partial = struct {
                fn partial(_: ?*anyopaque, _: [*c]const u8, _: usize, _: [*c]c.struct_mustach_sbuf) callconv(.C) c_int {
                    debug.print("partial\n", .{});
                    return 0;
                }
            }.partial,
        };

        pub fn parse(allocator: mem.Allocator, page: Page, writer: Writer) !void {
            var arena = heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var parser: Self = .{
                .arena = arena.allocator(),
                .page = page,
                .writer = writer,
            };

            switch (c.mini_mustach(
                @ptrCast(tmpl),
                tmpl.len,
                &Self.vtable,
                &parser,
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
                    debug.print("Uh oh! Error {any}\n", .{err});
                    return error.CouldNotRenderTemplate;
                },
                else => |value| {
                    debug.print("Received unknown value {d}\n", .{value});
                    unreachable;
                },
            }
        }
    };
}
