const c = @import("c");
const debug = std.debug;
const math = std.math;
const mem = std.mem;
const std = @import("std");

fn ProcessOutputType(comptime Writer: type) type {
    return struct {
        fn processOutput(buf: [*c]const u8, len: c_uint, ptr: ?*anyopaque) callconv(.C) void {
            const writer: *Writer = @ptrCast(@alignCast(ptr));
            writer.writeAll(buf[0..len]) catch {
                debug.print("Could not write markdown result.\n", .{});
                @panic("Markdown processing error.");
            };
        }
    };
}

pub fn renderStream(markdown: []const u8, writer: anytype) !void {
    const result = c.md_html(
        @ptrCast(markdown),
        @as(c_uint, @intCast(markdown.len)),
        ProcessOutputType(@TypeOf(writer)).processOutput,
        @constCast(@ptrCast(&writer)),
        0,
        0,
    );

    if (result != 0) {
        return error.CouldNotTransformMarkdown;
    }
}
