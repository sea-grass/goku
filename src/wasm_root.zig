pub const Site = @import("Site.zig");
pub const Database = @import("Database.zig");
pub const storage = @import("storage.zig");

export fn add(a: c_int, b: c_int) c_int {
    return a + b;
}
