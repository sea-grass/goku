const std = @import("std");

pub fn build(b: *std.Build) !void {
    // If this line is failing, you need to run `npm install`.
    _ = @embedFile("node_modules/htm/dist/htm.mjs");

    const wf = b.addWriteFiles();

    _ = wf.addCopyFile(b.path("node_modules/htm/dist/htm.mjs"), "htm.mjs");

    _ = b.addModule("htm", .{
        .root_source_file = wf.add(
            "root.zig",
            \\pub const mjs = @embedFile("htm.mjs");
            ,
        ),
    });
}
