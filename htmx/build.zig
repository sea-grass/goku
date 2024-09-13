const std = @import("std");

pub fn build(b: *std.Build) !void {
    const htmx_src = b.dependency("htmx_src", .{});

    const wf = b.addWriteFiles();

    _ = wf.addCopyDirectory(
        htmx_src.path("dist"),
        "dist",
        .{},
    );

    _ = b.addModule("htmx", .{
        .root_source_file = wf.addCopyFile(b.path("root.zig"), "root.zig"),
    });
}
