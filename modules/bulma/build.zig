const std = @import("std");

pub fn build(b: *std.Build) !void {
    const upstream = b.dependency("upstream", .{});

    const wf = b.addWriteFiles();

    _ = wf.addCopyDirectory(
        upstream.path("css"),
        "css",
        .{},
    );

    _ = b.addModule("bulma", .{
        .root_source_file = wf.add(
            "root.zig",
            \\pub const css = @embedFile("css/bulma.css");
            \\pub const min = .{
            \\    .css = @embedFile("css/bulma.min.css"),
            \\    .map = @embedFile("css/bulma.css.map"),
            \\};
            \\
            ,
        ),
    });
}
