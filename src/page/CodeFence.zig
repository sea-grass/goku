const debug = std.debug;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;
const log = std.log.scoped(.CodeFence);

const fence = "---";
const first_fence = fence ++ "\n";
const second_fence = "\n" ++ fence;

const CodeFence = @This();

within: []const u8,
after: []const u8,

pub fn parse(buf: []const u8) ?CodeFence {
    const first_index = mem.indexOf(u8, buf, first_fence) orelse return null;
    const start = first_index + first_fence.len;

    const end = second: {
        const offset = mem.indexOf(u8, buf[start..], second_fence) orelse return null;
        break :second start + offset;
    };

    const content_start = end + second_fence.len;

    return .{
        .within = buf[start..end],
        .after = if (content_start == buf.len) "" else buf[content_start..],
    };
}

test parse {
    try testing.expect(parse("") == null);
    try testing.expect(parse("---") == null);
    try testing.expect(parse("---\n") == null);
    try testing.expect(parse("---\n---") == null);

    try testing.expect(parse("---\n\n---") != null);

    const t = struct {
        pub inline fn within(expected: []const u8, input: []const u8) !void {
            const result = parse(input);
            try testing.expect(result != null);
            try testing.expectEqualStrings(expected, result.?.within);
        }
        pub inline fn after(expected: []const u8, input: []const u8) !void {
            const result = parse(input);
            try testing.expect(result != null);
            try testing.expectEqualStrings(expected, result.?.after);
        }
    };

    try t.within("", "---\n\n---");
    try t.after("", "---\n\n---");

    try t.within("\n", "---\n\n\n---");

    try t.within("id: foo", "---\nid: foo\n---");

    try t.after("\nFoobar", "---\n\n\n---\nFoobar");
}
