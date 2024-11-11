const BatchAllocator = @import("BatchAllocator.zig");
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const sqlite = @import("sqlite");
const std = @import("std");
const testing = std.testing;

allocator: mem.Allocator,
db: sqlite.Db,

pub const Page = Table("pages", .{
    .create =
    \\CREATE TABLE pages(slug TEXT, title TEXT, filepath TEXT, collection TEXT, date DATE);
    ,
    .insert =
    \\INSERT INTO pages(slug, title, filepath, collection, date) VALUES (?, ?, ?, ?, ?);
    ,
});

pub const Template = Table("templates", .{
    .create =
    \\CREATE TABLE templates(filepath TEXT);
    ,
    .insert =
    \\INSERT INTO templates(filepath) VALUES (?);
    ,
});

const Database = @This();

pub fn init(allocator: mem.Allocator) !Database {
    var db = try sqlite.Db.init(.{
        .mode = .Memory,
        .open_flags = .{ .write = true, .create = true },
        .threading_mode = .SingleThread,
    });
    errdefer db.deinit();

    return .{
        .allocator = allocator,
        .db = db,
    };
}

pub fn deinit(self: *Database) void {
    self.db.deinit();
}

fn Table(
    comptime table_name: []const u8,
    comptime statements: struct { create: []const u8, insert: ?[]const u8 },
) type {
    return struct {
        pub const name = table_name;

        pub fn init(db: *Database) !void {
            try db.db.exec(statements.create, .{}, .{});
        }

        pub fn insert(db: *Database, data: anytype) !void {
            if (statements.insert == null) {
                @compileError(fmt.comptimePrint("Table {s} does not support insert.\n", .{name}));
            }

            try db.db.execAlloc(
                db.allocator,
                statements.insert.?,
                .{},
                data,
            );
        }
    };
}

pub const IteratorTypeOptions = struct {
    stmt: []const u8,
    type: type,
};

/// A wrapper around a `sqlite.Database.Iterator` to handle batch memory
/// allocations for a given `SELECT` query.
pub fn IteratorType(comptime opts: IteratorTypeOptions) type {
    return struct {
        batch: BatchAllocator,
        stmt: sqlite.StatementType(.{}, opts.stmt),
        it: sqlite.Iterator(opts.type),

        const Iterator = @This();

        pub fn init(ally: mem.Allocator, db: *Database) !Iterator {
            var stmt = try db.db.prepare(opts.stmt);
            errdefer stmt.deinit();

            const it = try stmt.iterator(opts.type, .{});

            var batch = BatchAllocator.init(ally);
            errdefer batch.deinit();

            return .{
                .batch = batch,
                .stmt = stmt,
                .it = it,
            };
        }

        pub fn deinit(self: *Iterator) void {
            self.batch.deinit();
            self.stmt.deinit();
        }

        pub fn next(self: *Iterator) !?opts.type {
            self.batch.flush();

            return try self.it.nextAlloc(
                self.batch.allocator(),
                .{},
            );
        }
    };
}

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
