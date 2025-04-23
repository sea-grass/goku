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

const File = struct {
    // absolute path (realpath)
    path: []const u8,

    /// Maximum page file size (100KB)
    pub const max_bytes = 100 * 1024;

    pub fn readAll(file: File, allocator: mem.Allocator) ![]const u8 {
        var handle = try fs.openFileAbsolute(file.path, .{});
        defer handle.close();
        return try handle.readToEndAlloc(allocator, max_bytes);
    }
};

const Page = struct {
    file: File,
    node: std.SinglyLinkedList.Node,

    pub fn split(file_content: []const u8) !struct { []const u8, []const u8 } {
        if (!mem.eql(u8, file_content[0..3], "---")) return error.PageIsMissingFrontmatterFence;
        const fence_index = mem.indexOfPos(u8, file_content, 3, "---") orelse return error.PageIsMissingFrontmatterFence;

        const frontmatter = mem.trim(u8, file_content[3..fence_index], "\n");
        const content = mem.trimLeft(u8, file_content[fence_index + 3 ..], "\n");

        return .{ frontmatter, content };
    }
};

const Template = struct {
    file: File,

    pub const Map = std.StringHashMap(*Template);
};

const Component = struct {
    file: File,
    node: std.SinglyLinkedList.Node,
};

const Site = struct {
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
                .node = .{},
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
                        .node = .{},
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
};

const debug = std.debug;
const fs = std.fs;
const log = std.log.scoped(.experiment);
const mem = std.mem;
const std = @import("std");
const walker = @import("source/filesystem.zig").walker;
