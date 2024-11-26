const fs = @import("std").fs;

pub fn check(dir: *fs.Dir) !void {
    if (try exists(dir, "build.zig") or
        try exists(dir, "build.zig.zon") or
        try exists(dir, ".gitignore") or
        try exists(dir, "pages") or
        try exists(dir, "templates"))
    {
        return error.DirectoryNotEmpty;
    }
}

pub fn write(dir: *fs.Dir) !void {
    try dir.writeFile(.{
        .sub_path = "build.zig",
        .data = @embedFile("scaffold/site_template/build.zig"),
    });

    try dir.writeFile(.{
        .sub_path = "build.zig.zon",
        .data = @embedFile("scaffold/site_template/build.zig.zon"),
    });

    try dir.writeFile(.{
        .sub_path = ".gitignore",
        .data = @embedFile("scaffold/site_template/.gitignore"),
    });

    {
        var pages_dir = try dir.makeOpenPath("pages", .{});
        defer pages_dir.close();

        try pages_dir.writeFile(.{
            .sub_path = "index.md",
            .data = @embedFile("scaffold/site_template/pages/index.md"),
        });
    }

    {
        var templates_dir = try dir.makeOpenPath("templates", .{});
        defer templates_dir.close();

        try templates_dir.writeFile(.{
            .sub_path = "page.html",
            .data = @embedFile("scaffold/site_template/templates/page.html"),
        });
    }
}

fn exists(dir: *fs.Dir, sub_path: []const u8) !bool {
    _ = dir.statFile(sub_path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}
