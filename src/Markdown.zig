const std = @import("std");
const debug = std.debug;
const math = std.math;
const mem = std.mem;
const c = @import("c");

const MarkdownParser = @This();
const Callback = struct {
    pub fn process_output(out_buf: [*c]const u8, len: c_uint, ptr: ?*anyopaque) callconv(.C) void {
        const self: *MarkdownParser = @ptrCast(@alignCast(ptr));

        const d = out_buf[0..len];
        self.buf.appendSlice(d) catch {
            debug.print("Could not append markdown processing result to buffer.\n", .{});
            @panic("Markdown processing error.");
        };
    }
};

buf: std.ArrayList(u8),

pub fn init(allocator: mem.Allocator) MarkdownParser {
    return .{
        .buf = std.ArrayList(u8).init(allocator),
    };
}

pub fn deinit(self: MarkdownParser) void {
    self.buf.deinit();
}

pub fn renderStream(self: *MarkdownParser, markdown: []const u8, writer: anytype) !void {
    const result = c.md_html(
        @ptrCast(markdown),
        math.lossyCast(c_uint, markdown.len),
        Callback.process_output,
        self,
        0,
        0,
    );

    if (result != 0) {
        return error.CouldNotTransformMarkdown;
    }

    try writer.writeAll(self.buf.items);
}
