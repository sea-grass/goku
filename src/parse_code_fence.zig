const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const ParseCodeFenceResult = struct {
    within: []const u8,
    after: []const u8,
};

pub fn parseCodeFence(buf: []const u8) ?ParseCodeFenceResult {
    const fence = "---";

    const first_fence = fence ++ "\n";
    const first_index = mem.indexOf(u8, buf, first_fence) orelse return null;

    const second_fence = "\n" ++ fence;
    const second_index_offset = mem.indexOf(u8, buf[first_index + first_fence.len ..], "\n" ++ fence) orelse return null;
    const second_index = first_index + first_fence.len + second_index_offset;

    if (second_index <= first_index) return null;

    const after_index = second_index + second_fence.len;

    return .{
        .within = buf[first_index + first_fence.len .. second_index],
        .after = if (after_index == buf.len) "" else buf[after_index..buf.len],
    };
}

test parseCodeFence {
    try testing.expect(parseCodeFence("") == null);
    try testing.expect(parseCodeFence("---") == null);
    try testing.expect(parseCodeFence("---\n") == null);
    try testing.expect(parseCodeFence("---\n---") == null);

    try testing.expect(parseCodeFence("---\n\n---") != null);

    try testing.expectEqualStrings(parseCodeFence("---\n\n---").?.within, "");
    try testing.expectEqualStrings(parseCodeFence("---\n\n---").?.after, "");

    try testing.expectEqualStrings(parseCodeFence("---\n\n\n---").?.within, "\n");

    try testing.expectEqualStrings(parseCodeFence("---\nid: foo\n---").?.within, "id: foo");

    // TODO Fix these tests
    if (false) {
        try testing.expectEqual(6, parseCodeFence("---\n\n---\nFoobar").?.after.len);
        try testing.expectEqualStrings(parseCodeFence("---\n\n---\nFoobar").?.after, "Foobar");
    }
}
