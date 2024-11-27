const Database = @import("Database.zig");
const heap = std.heap;
const std = @import("std");
const testing = std.testing;

pub const Page = Database.Table(
    "pages",
    .{
        .create =
        \\CREATE TABLE pages(
        \\  slug TEXT,
        \\  title TEXT,
        \\  filepath TEXT,
        \\  template TEXT,
        \\  collection TEXT,
        \\  date DATE
        \\);
        ,
        .insert =
        \\INSERT INTO pages(
        \\  slug,
        \\  title,
        \\  filepath,
        \\  template,
        \\  collection,
        \\  date
        \\)
        \\VALUES
        \\(?, ?, ?, ?, ?, ?);
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

pub const Component = Database.Table(
    "components",
    .{
        .create =
        \\CREATE TABLE components(name TEXT, filepath TEXT);
        ,
        .insert =
        \\INSERT INTO components(name, filepath) VALUES (?, ?);
        ,
    },
);

test Page {
    var db = try Database.init(testing.allocator);
    defer db.deinit();

    try Page.init(&db);
    try Page.insert(&db, .{
        .slug = "/",
        .title = "Home page",
        .filepath = null,
        .template = null,
        .collection = null,
        .date = null,
    });

    var it = try Page.iterate(
        struct { slug: []const u8, date: []const u8, title: []const u8 },
        testing.allocator,
        &db,
    );

    defer it.deinit();

    const entry = try it.next();
    try testing.expect(entry != null);

    try testing.expectEqualStrings(entry.?.slug, "/");
    try testing.expectEqualStrings(entry.?.title, "Home page");

    try testing.expectEqual(null, try it.next());
}

test Template {
    var db = try Database.init(testing.allocator);
    defer db.deinit();

    try Template.init(&db);
    try Template.insert(&db, .{ .filepath = "/path/to/template.html" });

    var it = try Template.iterate(
        struct { filepath: []const u8 },
        testing.allocator,
        &db,
    );
    defer it.deinit();

    const entry = try it.next();
    try testing.expect(entry != null);

    try testing.expectEqualStrings(entry.?.filepath, "/path/to/template.html");

    try testing.expectEqual(null, try it.next());
}

test Component {
    var db = try Database.init(testing.allocator);
    defer db.deinit();

    try Component.init(&db);
    try Component.insert(&db, .{ .name = "component.js", .filepath = "/path/to/component.js" });

    var it = try Component.iterate(
        struct { filepath: []const u8 },
        testing.allocator,
        &db,
    );
    defer it.deinit();

    const entry = try it.next();
    try testing.expect(entry != null);

    try testing.expectEqualStrings(entry.?.filepath, "/path/to/component.js");

    try testing.expectEqual(null, try it.next());
}
