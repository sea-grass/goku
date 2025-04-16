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
    var site_dir = try std.fs.openDirAbsolute(site_path, .{});
    defer site_dir.close();

    try validateSiteDir(&site_dir);

    var site: Site = .init;
    defer site.deinit();

    var arena_impl: std.heap.ArenaAllocator = .init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var template_walker = walker(site_path, "templates");
    while (try template_walker.next()) |entry| {
        const realpath = try entry.realpathAlloc(arena);
        errdefer arena.free(realpath);

        const node = try arena.create(Template.List.Node);
        errdefer arena.destroy(node);

        node.* = .{ .data = .{ .path = realpath } };
        site.templates.prepend(node);
    }

    var page_walker = walker(site_path, "pages");
    while (try page_walker.next()) |entry| {
        const realpath = try entry.realpathAlloc(arena);
        errdefer arena.free(realpath);

        const node = try arena.create(Page.List.Node);
        errdefer arena.destroy(node);

        node.* = .{ .data = .{ .path = realpath } };
        site.pages.prepend(node);
    }

    if (site_dir.statFile("components")) |stat| switch (stat.kind) {
        .directory => {
            var component_walker = walker(site_path, "components");
            while (try component_walker.next()) |entry| {
                const realpath = try entry.realpathAlloc(arena);
                errdefer arena.free(realpath);

                const node = try arena.create(Component.List.Node);
                errdefer arena.destroy(node);

                node.* = .{ .data = .{ .path = realpath } };
                site.components.prepend(node);
            }
        },
        else => return error.ComponentsIsNotADir,
    } else |err| switch (err) {
        // components dir is optional
        error.FileNotFound => {},
        else => return err,
    }

    {
        var curr = site.pages.first;
        while (curr) |p| {
            log.info("{s}", .{p.data.path});
            curr = p.next;
        }
    }

    {
        var curr = site.templates.first;
        while (curr) |p| {
            log.info("{s}", .{p.data.path});
            curr = p.next;
        }
    }

    {
        var curr = site.components.first;
        while (curr) |p| {
            log.info("{s}", .{p.data.path});
            curr = p.next;
        }
    }
}

const Page = struct {
    // absolute path (realpath)
    path: []const u8,

    pub const List = std.SinglyLinkedList(Page);
};

const Template = struct {
    // absolute path (realpath)
    path: []const u8,

    pub const List = std.SinglyLinkedList(Template);
};

const Component = struct {
    // absolute path (realpath)
    path: []const u8,

    pub const List = std.SinglyLinkedList(Component);
};

const Site = struct {
    pages: Page.List,
    templates: Template.List,
    components: Component.List,

    pub const init: Site = .{
        .pages = .{ .first = null },
        .templates = .{ .first = null },
        .components = .{ .first = null },
    };
    pub fn deinit(site: *Site) void {
        _ = site;
    }
};

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
        else => return error.ComponentsIsNotADir,
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
const walker = @import("source/filesystem.zig").walker;
