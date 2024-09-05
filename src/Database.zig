const fmt = @import("fmt");
const mem = std.mem;
const sqlite = @import("sqlite");
const std = @import("std");

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

    var self: Database = .{ .allocator = allocator, .db = db };

    try Page.init(&self);
    try Template.init(&self);

    return self;
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
