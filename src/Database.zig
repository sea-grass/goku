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

pub fn Table(
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
