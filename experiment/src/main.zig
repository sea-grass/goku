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

    try siteCommand(allocator, site_path);
}

fn siteCommand(allocator: mem.Allocator, site_path: []const u8) !void {
    debug.assert(std.fs.path.isAbsolute(site_path));
    var site_dir = try std.fs.openDirAbsolute(site_path, .{});
    defer site_dir.close();

    try Site.validateDir(&site_dir);

    var site: Site = .init(allocator);
    defer site.deinit();

    // Just using an arena allocator for ease of use.
    // I make use of defer frees where I remember, but in general,
    // I'm "deferring" figuring out the memory management logic for
    // Site as a whole until the models are reliably laid out.
    var arena_impl: std.heap.ArenaAllocator = .init(allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    try site.readDir(arena, &site_dir);

    {
        var curr = site.pages.first;
        while (curr) |node| {
            const page: *Page = @fieldParentPtr("node", node);
            const data = try page.file.readAll(allocator);
            defer allocator.free(data);

            const frontmatter, const content = try Page.split(data);

            const template_name = template: {
                var it = mem.splitScalar(u8, frontmatter, '\n');
                while (it.next()) |line| {
                    if (mem.startsWith(u8, line, "template:")) {
                        break :template mem.trim(u8, line["template:".len..], " ");
                    }
                }

                log.err("Error: Page({s}) is missing frontmatter attribute 'template'", .{page.file.path});
                return error.PageMissingFrontmatterAttributeTemplate;
            };

            const template: *const Template = site.templates.get(template_name) orelse {
                log.err("Error: Page({s}) references non-existent Template({s})", .{ page.file.path, template_name });
                return error.PageReferencesNonExistentTemplate;
            };

            log.info("{s} ({d} bytes)\n- (fm {d} bytes)\n- (content {d} bytes)\n- (template {s})\n", .{ page.file.path, data.len, frontmatter.len, content.len, template.*.file.path });
            log.info("{s}", .{frontmatter});

            curr = node.next;
        }
    }

    {
        var it = site.templates.iterator();
        while (it.next()) |entry| {
            log.info("template {s}", .{entry.key_ptr.*});
        }
    }

    {
        var curr = site.components.first;
        while (curr) |node| {
            const component: *Component = @fieldParentPtr("node", node);
            log.info("{s}", .{component.file.path});
            curr = node.next;
        }
    }
}

const debug = std.debug;
const fs = std.fs;
const log = std.log.scoped(.experiment);
const mem = std.mem;
const std = @import("std");
const walker = @import("source/filesystem.zig").walker;
const Site = @import("Site.zig");
const Page = @import("Page.zig");
const Template = @import("Template.zig");
const Component = @import("Component.zig");
