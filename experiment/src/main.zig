pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // skip exe name
    _ = args.next();

    const site_path = path: {
        const path = args.next() orelse return error.MissingSitePath;
        if (std.fs.path.isAbsolute(path)) break :path try allocator.dupe(u8, path);

        break :path try std.fs.cwd().realpathAlloc(allocator, path);
    };
    defer allocator.free(site_path);

    debug.assert(std.fs.path.isAbsolute(site_path));

    log.info("site{s}", .{site_path});

    var site_dir = try std.fs.openDirAbsolute(site_path, .{});
    defer site_dir.close();

    try validateSiteDir(&site_dir);
}

fn validateSiteDir(dir: *fs.Dir) !void {
    if (dir.statFile("pages")) |stat| switch (stat.kind) {
        .directory => {},
        else => return error.PagesIsNotADir,
    } else |err| switch (err) {
        error.FileNotFound => return error.MissingPagesDir,
        else => return err,
    }

    if (dir.statFile("templates")) |stat| switch (stat.kind) {
        .directory => {},
        else => return error.TemplatesIsNotADir,
    } else |err| switch (err) {
        error.FileNotFound => return error.MissingTemplatesDir,
        else => return err,
    }

    if (dir.statFile("components")) |stat| switch (stat.kind) {
        .directory => {},
        else => return error.PagesIsNotADir,
    } else |err| switch (err) {
        // components dir is optional
        error.FileNotFound => {},
        else => return err,
    }
}

const debug = std.debug;
const fs = std.fs;
const log = std.log.scoped(.experiment);
const std = @import("std");
