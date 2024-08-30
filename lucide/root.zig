const icons = @import("icons");
const log = std.log.scoped(.lucide);
const mem = std.mem;
const std = @import("std");

pub fn embedIconZ(comptime name: []const u8) [:0]const u8 {
    return @embedFile("icons/" ++ name ++ ".svg");
}

pub fn icon(name: []const u8) []const u8 {
    inline for (@typeInfo(icons).Struct.decls) |decl| {
        if (mem.eql(u8, decl.name, name)) {
            return @field(icons, decl.name);
        }
    }

    log.err("Unknown icon ({s})\n", .{name});
    @panic("Unknown icon. Did you forget to add it to the lucide dependency's `icons` list?");
}
