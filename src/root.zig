pub const BatchAllocator = @import("BatchAllocator.zig");
pub const c = @import("c");
pub const Database = @import("Database.zig");
pub const Goku = @import("Goku.zig");
pub const js = @import("js.zig");
pub const markdown = @import("markdown.zig");
pub const mustache = @import("mustache.zig");
pub const page = @import("page.zig");
pub const Site = @import("Site.zig");
pub const @"source/filesystem" = @import("source/filesystem.zig");
pub const storage = @import("storage.zig");
pub const httpz = @import("httpz");

test {
    @import("std").testing.refAllDecls(@This());
}

test {
    _ = @import("bulma");
    _ = @import("htmx");
}

test {
    _ = @import("main.zig");
    _ = @import("serve.zig");
}
