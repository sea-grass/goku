const fs = std.fs;
const log = std.log.scoped(.build_lucide);
const math = std.math;
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const lucide_src = b.dependency("icons", .{});
    const embedded_icons = b.option([]const []const u8, "icons", "The icons to embed into the generated module.");

    const wf = b.addWriteFiles();

    _ = wf.addCopyDirectory(
        lucide_src.path("icons"),
        "icons",
        .{},
    );

    const mod = b.addModule("lucide", .{
        .root_source_file = wf.addCopyFile(b.path("root.zig"), "root.zig"),
    });

    const options = b.addOptions();

    if (embedded_icons) |icons| {
        for (icons) |i| {
            const path = lucide_src.path(b.fmt("icons/{s}.svg", .{i}));

            const file = fs.openFileAbsolute(path.getPath(b), .{}) catch |err| {
                log.err("Could not load icon ({s})\n", .{i});
                return err;
            };

            const svg = try file.readToEndAlloc(b.allocator, math.maxInt(u32));
            options.addOption([]const u8, i, svg);
        }
    }

    mod.addOptions("icons", options);
}
