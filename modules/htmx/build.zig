const std = @import("std");

pub fn build(b: *std.Build) !void {
    const upstream = b.dependency("upstream", .{});

    const wf = b.addWriteFiles();

    _ = wf.addCopyDirectory(
        upstream.path("dist"),
        "dist",
        .{},
    );

    _ = b.addModule("htmx", .{
        .root_source_file = wf.add(
            "root.zig",
            \\pub const js = @embedFile("dist/htmx.js");
            \\pub const min = .{
            \\    .js = @embedFile("dist/htmx.min.js"),
            \\};
            ,
        ),
    });
}
