const Site = @This();

pages: std.SinglyLinkedList,
templates: Template.Map,
components: std.SinglyLinkedList,

pub fn init(allocator: mem.Allocator) Site {
    return .{
        .pages = .{},
        .templates = .init(allocator),
        .components = .{},
    };
}

pub fn deinit(site: *Site) void {
    site.templates.deinit();
}

pub fn validateDir(dir: *fs.Dir) !void {
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

pub fn readDir(site: *Site, arena: mem.Allocator, site_dir: *fs.Dir) !void {
    var site_path_buf: [fs.max_path_bytes]u8 = undefined;
    const site_path: []const u8 = try site_dir.realpath(".", &site_path_buf);

    var template_walker = walker(site_path, "templates");
    while (try template_walker.next()) |entry| {
        // Template files must end with .html - all other files are ignored.
        if (!mem.endsWith(u8, entry.subpath, ".html")) continue;

        const realpath = try entry.realpathAlloc(arena);
        errdefer arena.free(realpath);

        const name = try arena.dupe(u8, entry.subpath);

        const node = try arena.create(Template);
        errdefer arena.destroy(node);

        node.* = .{ .file = .{ .path = realpath } };
        try site.templates.put(name, node);
    }

    var page_walker = walker(site_path, "pages");
    while (try page_walker.next()) |entry| {
        const realpath = try entry.realpathAlloc(arena);
        errdefer arena.free(realpath);

        const page = try arena.create(Page);
        errdefer arena.destroy(page);

        page.* = .{
            .file = .{ .path = realpath },
        };

        site.pages.prepend(&page.node);
    }

    if (site_dir.statFile("components")) |stat| switch (stat.kind) {
        .directory => {
            var component_walker = walker(site_path, "components");
            while (try component_walker.next()) |entry| {
                const realpath = try entry.realpathAlloc(arena);
                errdefer arena.free(realpath);

                const component = try arena.create(Component);
                errdefer arena.destroy(component);
                component.* = .{
                    .file = .{ .path = realpath },
                };
                site.components.prepend(&component.node);
            }
        },
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
const mem = std.mem;
const std = @import("std");
const walker = @import("source/filesystem.zig").walker;
const Template = @import("Template.zig");
const Page = @import("Page.zig");
const Component = @import("Component.zig");
