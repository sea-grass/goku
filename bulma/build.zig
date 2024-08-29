const std = @import("std");

pub fn build(b: *std.Build) !void {
    const bulma_src = b.dependency("bulma_src", .{});

    const wf = b.addWriteFiles();

    _ = wf.addCopyDirectory(
        bulma_src.path("css"),
        "css",
        .{},
    );

    _ = b.addModule("bulma", .{
        .root_source_file = wf.addCopyFile(b.path("root.zig"), "root.zig"),
    });
}
