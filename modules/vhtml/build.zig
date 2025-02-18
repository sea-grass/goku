const std = @import("std");

pub fn build(b: *std.Build) !void {
    // If this line is failing, you need to run `npm install`.
    _ = @embedFile("node_modules/vhtml/dist/vhtml.js");

    const wf = b.addWriteFiles();

    _ = wf.addCopyFile(b.path("node_modules/vhtml/dist/vhtml.js"), "vhtml.js");

    _ = b.addModule("vhtml", .{
        .root_source_file = wf.add(
            "root.zig",
            \\pub const js = @embedFile("vhtml.js");
            ,
        ),
    });
}
