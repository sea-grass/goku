pub const Data = @import("page/Data.zig");
pub const Page = @import("page/page.zig").Page;
pub const CodeFence = @import("page/CodeFence.zig");

test {
    _ = @import("page/CodeFence.zig");
    _ = @import("page/Data.zig");
}
