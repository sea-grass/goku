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
    inline for (&.{
        "build.zig",
        "build.zig.zon",
        ".gitignore",
    }) |sub_path| {
        try dir.writeFile(.{
            .sub_path = sub_path,
            .data = @embedFile("scaffold/site_template/" ++ sub_path),
        });
    }

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
