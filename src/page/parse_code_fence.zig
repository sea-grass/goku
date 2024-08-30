const debug = std.debug;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

const fence = "---";
const first_fence = fence ++ "\n";
const second_fence = "\n" ++ fence;

pub const ParseCodeFenceResult = @This();

within: []const u8,
after: []const u8,

pub fn parseCodeFence(buf: []const u8) ?ParseCodeFenceResult {
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

test parseCodeFence {
    try testing.expect(parseCodeFence("") == null);
    try testing.expect(parseCodeFence("---") == null);
    try testing.expect(parseCodeFence("---\n") == null);
    try testing.expect(parseCodeFence("---\n---") == null);

    try testing.expect(parseCodeFence("---\n\n---") != null);

    try testing.expectEqualStrings(
        "",
        parseCodeFence("---\n\n---").?.within,
    );
    try testing.expectEqualStrings(
        "",
        parseCodeFence("---\n\n---").?.after,
    );

    try testing.expectEqualStrings(
        "\n",
        parseCodeFence("---\n\n\n---").?.within,
    );

    try testing.expectEqualStrings(
        "id: foo",
        parseCodeFence("---\nid: foo\n---").?.within,
    );

    try testing.expectEqualStrings(
        "\nFoobar",
        parseCodeFence("---\n\n---\nFoobar").?.after,
    );
    try testing.expectEqual(
        7,
        parseCodeFence("---\n\n---\nFoobar").?.after.len,
    );
}
