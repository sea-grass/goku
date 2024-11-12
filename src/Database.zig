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

        pub fn iterator(comptime DestType: type, ally: mem.Allocator, db: *Database) !Iterator(DestType) {
            return try Iterator(DestType).init(ally, db);
        }

        pub fn Iterator(comptime DestType: type) type {
            return IteratorType(.{
                .stmt = select(DestType),
                .type = DestType,
            });
        }

        comptime {
            debug.assert(
                mem.eql(
                    u8,
                    "select a, b, c, d from " ++ table_name,
                    select(
                        struct { a: u8, b: u8, c: u8, d: u8 },
                    ),
                ),
            );
        }

        fn select(comptime DestType: type) []const u8 {
            return statement.select(table_name, DestType);
        }
    };
}

pub const statement = struct {
    pub fn select(
        comptime table_name: []const u8,
        comptime DestType: type,
    ) []const u8 {
        const Fields = ComptimeWrite(struct {
            pub fn write(writer: anytype) !void {
                inline for (
                    @typeInfo(DestType).@"struct".fields,
                    0..,
                ) |
                    field,
                    i,
                | try writer.print(
                    switch (i) {
                        0 => "{s}",
                        else => ", {s}",
                    },
                    .{field.name},
                );
            }
        });

        return fmt.comptimePrint(
            "select {[fields]s} from {[table]s}",
            .{ .fields = Fields{}, .table = table_name },
        );
    }
};

pub const IteratorTypeOptions = struct {
    stmt: []const u8,
    type: type,
};

/// A wrapper around a `sqlite.Database.Iterator` to handle batch memory
/// allocations for a given `SELECT` query.
///
/// Example usage:
/// ```
/// var db = Database.init(allocator);
/// defer db.deinit();
///
/// const Position = struct {
///   x: u8, y: u8, z: u8,
///
///   pub const Table = Database.Table("position", ...);
/// };
///
/// try Position.Table.init(&db);
///
/// // Insert test data into table...
///
/// // This iterator will only lookup the `x` column.
/// const Iterator = IteratorType(.{
///   .stmt = Position.Table.select(struct { x: u8 }),
///   .type = Position,
/// });
///
/// var it = try Iterator.init(allocator, &db);
/// defer it.deinit();
///
/// while (try it.next()) |pos| {
///   try std.io.getStdOut().writer().print("(x) = ({d})\n", .{ pos.x });
/// }
/// ```
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

/// Provides a comptime way to procedurally generate a string,
/// using a custom format function for `std.fmt.format` and
/// zero-sized structs. No allocators and no state beyond the
/// call to `write`.
///
/// Example:
/// ```
/// const Write = ComptimeWrite(struct {
///   pub fn write(writer: anytype) !void {
///     try writer.print("Hello, world.\n", .{});
///   }
/// });
///
/// // "Hello, world.\n"
/// const greeting = fmt.comptimePrint("{s}", .{ Write{} });
/// ```
fn ComptimeWrite(comptime Write: type) type {
    return struct {
        comptime {
            debug.assert(@sizeOf(Write) == 0);
            // Either explicitly use a `packed struct(u0)` or trust that
            // the compiler knows to make it zero-sized?
            debug.assert(@sizeOf(@This()) == 0);
        }

        pub fn format(
            _: @This(),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try Write.write(writer);
        }
    };
}
