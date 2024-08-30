pub const Data = @import("page/Data.zig");
pub const Page = @import("page/page.zig").Page;
pub const parseCodeFence = @import("page/parse_code_fence.zig").parseCodeFence;

test {
    _ = @import("page/parse_code_fence.zig");
    _ = @import("page/Data.zig");
}
