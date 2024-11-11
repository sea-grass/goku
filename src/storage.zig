const Database = @import("Database.zig");
const heap = std.heap;
const std = @import("std");
const testing = std.testing;

pub const Page = Database.Table(
    "pages",
    .{
        .create =
        \\CREATE TABLE pages(slug TEXT, title TEXT, filepath TEXT, collection TEXT, date DATE);
        ,
        .insert =
        \\INSERT INTO pages(slug, title, filepath, collection, date) VALUES (?, ?, ?, ?, ?);
        ,
    },
);

pub const Template = Database.Table(
    "templates",
    .{
        .create =
        \\CREATE TABLE templates(filepath TEXT);
        ,
        .insert =
        \\INSERT INTO templates(filepath) VALUES (?);
        ,
    },
);

test "Page" {
    var db = try Database.init(testing.allocator);
    defer db.deinit();

    try Page.init(&db);
    try Page.insert(&db, .{
        .slug = "/",
        .title = "Home page",
        .filepath = null,
        .collection = null,
        .date = null,
    });

    const query = "SELECT slug, date, title FROM pages";
    var get_stmt = try db.db.prepare(query);
    defer get_stmt.deinit();

    var it = try get_stmt.iterator(
        struct { slug: []const u8, date: []const u8, title: []const u8 },
        .{},
    );

    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const entry = try it.nextAlloc(arena.allocator(), .{});
    try testing.expect(entry != null);

    try testing.expectEqualStrings(entry.?.slug, "/");
    try testing.expectEqualStrings(entry.?.title, "Home page");

    try testing.expectEqual(null, try it.nextAlloc(arena.allocator(), .{}));
}

test "Template" {
    var db = try Database.init(testing.allocator);
    defer db.deinit();

    try Template.init(&db);
    try Template.insert(&db, .{ .filepath = "/path/to/template.html" });

    const query = "SELECT filepath FROM templates";
    var get_stmt = try db.db.prepare(query);
    defer get_stmt.deinit();

    var it = try get_stmt.iterator(struct { filepath: []const u8 }, .{});

    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const entry = try it.nextAlloc(arena.allocator(), .{});
    try testing.expect(entry != null);

    try testing.expectEqualStrings(entry.?.filepath, "/path/to/template.html");

    try testing.expectEqual(null, try it.nextAlloc(arena.allocator(), .{}));
}
