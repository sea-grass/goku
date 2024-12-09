const c = @import("c");
const std = @import("std");

test "invalid itf" {
    const template: []const u8 = "Hello {{world}}";
    const itf: c.mustach_itf = .{};

    var closure: struct {} = .{};
    const flags: c_int = 0;

    var str: ?[]const u8 = null;
    var len: usize = 0;

    const result = c.mustach_mem(
        @ptrCast(template),
        template.len,
        &itf,
        @ptrCast(@alignCast(&closure)),
        flags,
        @ptrCast(@alignCast(&str)),
        &len,
    );

    try std.testing.expectEqual(c.MUSTACH_ERROR_INVALID_ITF, result);
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("\n\n" ++ fmt, args) catch {};
}
