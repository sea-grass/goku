//! Custom test runner
//!
//! Based on:
//!     https://gist.github.com/karlseguin/c6bea5b35e4e8d26af6f81c22cb5d76b
//!
//! In your build.zig, you can specify a custom test runner:
//! ```
//! const tests = b.addTest(.{
//!   .target = target,
//!   .optimize = optimize,
//!   .test_runner = "test_runner.zig", // add this line
//!   .root_source_file = b.path("src/main.zig"),
//! });
//! ```

const ascii = std.ascii;
const builtin = std.builtin;
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const log = std.log;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const std = @import("std");
const testing = std.testing;
const time = std.time;

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);
    var arena = heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();

    const env = try Env.parse(&arena);

    var slowest = try SlowTracker.init(
        fba.allocator(),
        5,
    );
    defer slowest.deinit();

    var stats: Statistics = .{};

    const stderr = io.getStdErr().writer();

    // beginning of line and clear to end of line
    try stderr.print("\r\x1b[0K", .{});

    for (@import("builtin").test_functions) |t| {
        if (env.filter) |filter| {
            if (!isUnnamed(t) and
                mem.indexOf(u8, t.name, filter) == null)
            {
                continue;
            }
        }

        const result = try runTest(
            t,
            .{ .slowest = &slowest },
        );

        stats.record(result);
        try result.write(env.verbose, stderr);

        switch (result.status) {
            .fail => {
                if (env.fail_first) {
                    break;
                } else {
                    continue;
                }
            },
            else => {},
        }
    }

    try stats.write(stderr);

    try stderr.print("\n", .{});
    try slowest.write(stderr);
    try stderr.print("\n", .{});

    posix.exit(
        if (stats.allPass())
            0
        else
            1,
    );
}

const BORDER = "=" ** 80;

const Status = enum {
    pass,
    fail,
    skip,
};

const Statistics = struct {
    pass: usize = 0,
    fail: usize = 0,
    skip: usize = 0,
    leak: usize = 0,

    pub fn total(self: Statistics) usize {
        return self.pass + self.fail;
    }

    pub fn allPass(self: Statistics) bool {
        return self.fail == 0 and self.leak == 0;
    }

    pub fn record(stats: *Statistics, result: Result) void {
        if (result.leak) {
            stats.leak += 1;
        }

        switch (result.status) {
            .fail => {
                stats.fail += 1;
            },
            .skip => {
                stats.skip += 1;
            },
            .pass => {
                stats.pass += 1;
            },
        }
    }

    pub fn write(stats: Statistics, writer: anytype) !void {
        const total_tests = stats.total();
        const status: enum { pass, fail } = if (stats.fail == 0 and stats.leak == 0)
            .pass
        else
            .fail;

        {
            const colour = Colour.fromTestStatus(switch (status) {
                .pass => .pass,
                .fail => .fail,
            });

            try colour.write(writer);
            try writer.print(
                "\n{d} of {d} test{s} passed\n",
                .{ stats.pass, total_tests, if (total_tests != 1) "s" else "" },
            );
            try Colour.reset(writer);
        }

        if (stats.skip > 0) {
            const colour = Colour.fromTestStatus(.skip);

            try colour.write(writer);
            try writer.print(
                "{d} test{s} skipped\n",
                .{ stats.skip, if (stats.skip != 1) "s" else "" },
            );
            try Colour.reset(writer);
        }

        if (stats.leak > 0) {
            const colour = Colour.fromTestStatus(.fail);

            try colour.write(writer);
            try writer.print(
                "{d} test{s} leaked\n",
                .{ stats.leak, if (stats.leak != 1) "s" else "" },
            );
            try Colour.reset(writer);
        }
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    pub fn parse(arena: *heap.ArenaAllocator) !Env {
        return .{
            .verbose = try readEnv(
                bool,
                arena,
                "TEST_VERBOSE",
            ) orelse true,
            .fail_first = try readEnv(
                bool,
                arena,
                "TEST_FAIL_FIRST",
            ) orelse true,
            .filter = try readEnv(
                []const u8,
                arena,
                "TEST_FILTER",
            ),
        };
    }

    // If T is []const u8, caller owns the result.
    fn readEnv(comptime T: type, arena: *heap.ArenaAllocator, key: []const u8) !?T {
        switch (T) {
            []const u8, bool => {},
            else => @compileError("readEnv for T not implemented"),
        }

        const value = process.getEnvVarOwned(
            arena.allocator(),
            key,
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                return null;
            },
            else => {
                log.warn("failed to get env var {s} due to err {any}", .{ key, err });
                return null;
            },
        };
        errdefer arena.allocator().free(value);

        switch (T) {
            []const u8 => {
                return value;
            },
            bool => {
                defer arena.allocator().free(value);
                return ascii.eqlIgnoreCase(value, "true");
            },
            else => unreachable,
        }
    }
};

const Colour = enum {
    pass,
    fail,
    skip,

    pub fn fromTestStatus(status: Status) Colour {
        return switch (status) {
            .pass => .pass,
            .fail => .fail,
            .skip => .skip,
        };
    }

    pub fn write(self: Colour, writer: anytype) !void {
        try writer.writeAll(switch (self) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
        });
    }

    pub fn reset(writer: anytype) !void {
        try writer.writeAll("\x1b[0m");
    }
};

const SlowTracker = struct {
    max: usize,
    slowest: SlowestQueue,
    timer: time.Timer,

    const TestInfo = struct {
        elapsed_ns: u64,
        name: []const u8,
        status: Status,

        const sort_field = "elapsed_ns";

        fn sort(_: void, a: TestInfo, b: TestInfo) math.Order {
            return math.order(
                @field(a, sort_field),
                @field(b, sort_field),
            );
        }
    };

    const SlowestQueue = std.PriorityDequeue(
        TestInfo,
        void,
        TestInfo.sort,
    );

    fn init(allocator: mem.Allocator, count: u32) !SlowTracker {
        const timer = try time.Timer.start();
        var slowest = SlowestQueue.init(
            allocator,
            {},
        );
        errdefer slowest.deinit();

        try slowest.ensureTotalCapacity(count);

        return .{
            .max = count,
            .timer = timer,
            .slowest = slowest,
        };
    }

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8, status: Status) !u64 {
        const elapsed_ns = self.timer.lap();

        // If our queue max is 0, we don't care to track timings,
        // so we don't bother to modify the queue.
        if (self.max == 0) return elapsed_ns;

        const test_info: TestInfo = .{
            .elapsed_ns = elapsed_ns,
            .name = test_name,
            .status = status,
        };

        // Keep tracking tests if we're under max capacity
        if (self.slowest.count() < self.max) {
            try self.slowest.add(test_info);

            return elapsed_ns;
        }

        // We've exceeded max capacity and the queue will contain
        // at least one element.
        const smallest_test_info = self.slowest.peekMin() orelse unreachable;

        switch (TestInfo.sort(
            {},
            smallest_test_info,
            test_info,
        )) {
            // The existing smallest test should remain in the queue
            .eq, .gt => {
                return elapsed_ns;
            },
            // The current test should replace the existing queue item
            .lt => {
                _ = self.slowest.removeMin();
                try self.slowest.add(test_info);

                return elapsed_ns;
            },
        }
    }

    fn write(self: *SlowTracker, writer: anytype) !void {
        const count = self.slowest.count();
        try writer.print("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });

        while (self.slowest.removeMaxOrNull()) |info| {
            const elapsed_ms = @as(f64, @floatFromInt(info.elapsed_ns)) / 1_000_000.0;
            try writer.print(
                "  {d:6.2}ms\t{s}\t{s}\n",
                .{
                    elapsed_ms,
                    switch (info.status) {
                        .pass => "pass",
                        .fail => "fail",
                        .skip => "skip",
                    },
                    info.name,
                },
            );
        }
    }
};

const Result = struct {
    status: Status,
    leak: bool,
    elapsed_ns: u64,
    test_name: []const u8,

    pub fn write(result: Result, verbose: bool, writer: anytype) !void {
        if (result.leak) {
            const colour = Colour.fromTestStatus(.fail);

            try colour.write(writer);
            try writer.print("\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, result.test_name, BORDER });
            try Colour.reset(writer);
        }

        switch (result.status) {
            .fail => {
                const colour = Colour.fromTestStatus(.fail);

                try colour.write(writer);
                try writer.print("\n{s}\n\"{s}\"\n{s}\n", .{ BORDER, result.test_name, BORDER });
                try Colour.reset(writer);

                // TODO I'll need this function to encounter an error in
                // order to use this.
                if (@errorReturnTrace()) |trace| {
                    debug.dumpStackTrace(trace.*);
                }
            },
            else => {},
        }

        if (verbose) {
            const elapsed_ms = @as(f64, @floatFromInt(result.elapsed_ns)) / 1_000_000.0;

            const colour = Colour.fromTestStatus(result.status);

            try colour.write(writer);
            try writer.print(
                "{s} ({d:.2}ms)\n",
                .{ result.test_name, elapsed_ms },
            );
            try Colour.reset(writer);
        } else {
            const colour = Colour.fromTestStatus(result.status);

            try colour.write(writer);
            try writer.print(".", .{});
            try Colour.reset(writer);
        }
    }
};

const RunTestOptions = struct {
    slowest: *SlowTracker,
};

fn runTest(
    t: builtin.TestFn,
    options: RunTestOptions,
) !Result {
    options.slowest.startTiming();

    const friendly_name = friendlyName(t.name);
    testing.allocator_instance = .{};

    current_test = friendly_name;
    const result = t.func();
    current_test = null;

    const status: Status = if (result) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => .fail,
    };

    const elapsed_ns = try options.slowest.endTiming(
        friendly_name,
        status,
    );

    const leak = testing.allocator_instance.deinit() == .leak;

    return .{
        .leak = leak,
        .elapsed_ns = elapsed_ns,
        .test_name = friendly_name,
        .status = if (result) |_| .pass else |err| switch (err) {
            error.SkipZigTest => .skip,
            else => .fail,
        },
    };
}

fn friendlyName(name: []const u8) []const u8 {
    const noisy_prefix = "test.";

    return if (mem.startsWith(u8, name, noisy_prefix) and
        name.len > noisy_prefix.len)
        name[noisy_prefix.len..]
    else
        name;
}

// Unnamed tests look like:
// namespace.test_#
//
// isUnnamed will return true if the provided TestFn has a name which
// ends with `.test_#`, where `#` is a valid integer.
//
// Note that this means that it may return true even for named tests
// if they match this pattern.
fn isUnnamed(t: builtin.TestFn) bool {
    const marker = ".test_";

    if (mem.indexOf(u8, t.name, marker)) |index| {
        const tail = t.name[index + marker.len ..];
        _ = fmt.parseInt(usize, tail, 10) catch {
            return false;
        };
        return true;
    }

    return false;
}

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (current_test) |ct| {
        debug.print("\x1b[31m{[border]s}\npanic running \"{[name]s}\"\n{[border]s}\x1b[0m\n", .{
            .border = BORDER,
            .name = ct,
        });
    }

    debug.defaultPanic(msg, error_return_trace, ret_addr);
}
