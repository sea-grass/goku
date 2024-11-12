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
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const std = @import("std");
const time = std.time;

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);

    var arena = heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();

    const env = try Env.parse(&arena);

    var slowest = try SlowTracker.init(fba.allocator(), 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

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

        runTest(
            t,
            env,
            &slowest,
            &leak,
            &pass,
            &skip,
            &fail,
            stderr,
        ) catch |err| switch (err) {
            error.FailFirst => {
                break;
            },
            else => {
                continue;
            },
        };
    }

    const total_tests = pass + fail;
    const status: enum { pass, fail } = if (fail == 0 and leak == 0)
        .pass
    else
        .fail;

    {
        const colour = Colour.fromTestStatus(switch (status) {
            .pass => .pass,
            .fail => .fail,
        });

        try colour.write(stderr);
        try stderr.print(
            "\n{d} of {d} test{s} passed\n",
            .{ pass, total_tests, if (total_tests != 1) "s" else "" },
        );
        try Colour.reset(stderr);
    }

    if (skip > 0) {
        const colour = Colour.fromTestStatus(.skip);

        try colour.write(stderr);
        try stderr.print("{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
        try Colour.reset(stderr);
    }

    if (leak > 0) {
        const colour = Colour.fromTestStatus(.fail);

        try colour.write(stderr);
        try stderr.print("{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
        try Colour.reset(stderr);
    }

    try stderr.print("\n", .{});
    try slowest.write(stderr);
    try stderr.print("\n", .{});

    posix.exit(
        switch (status) {
            .pass => 0,
            .fail => 1,
        },
    );
}

const BORDER = "=" ** 80;

const Status = enum {
    pass,
    fail,
    skip,
};

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (current_test) |ct| {
        std.debug.print("\x1b[31m{[border]s}\npanic running \"{[name]s}\"\n{[border]s}\x1b[0m\n", .{
            .border = BORDER,
            .name = ct,
        });
    }

    std.debug.defaultPanic(msg, error_return_trace, ret_addr);
}

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
                std.log.warn("failed to get env var {s} due to err {any}", .{ key, err });
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
                "  {d:12.6}ms\t{s}\t{s}\n",
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

fn runTest(
    t: builtin.TestFn,
    env: Env,
    slowest: *SlowTracker,
    leak: *usize,
    pass: *usize,
    skip: *usize,
    fail: *usize,
    writer: anytype,
) !void {
    slowest.startTiming();

    const friendly_name = friendlyName(t.name);
    current_test = friendly_name;
    std.testing.allocator_instance = .{};
    const result = t.func();
    current_test = null;

    const status: Status = if (result) |_| .pass else |err| switch (err) {
        error.SkipZigTest => .skip,
        else => .fail,
    };
    const elapsed_ns = try slowest.endTiming(
        friendly_name,
        status,
    );

    if (std.testing.allocator_instance.deinit() == .leak) {
        leak.* += 1;
        const colour = Colour.fromTestStatus(.fail);

        try colour.write(writer);
        try writer.print("\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
        try Colour.reset(writer);
    }

    if (result) |_| {
        pass.* += 1;
    } else |err| switch (err) {
        error.SkipZigTest => {
            skip.* += 1;
        },
        else => {
            fail.* += 1;

            const colour = Colour.fromTestStatus(.fail);

            try colour.write(writer);
            try writer.print("\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
            try Colour.reset(writer);

            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            if (env.fail_first) {
                return error.FailFirst;
            }
        },
    }

    if (env.verbose) {
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        const colour = Colour.fromTestStatus(status);

        try colour.write(writer);
        try writer.print(
            "{s} ({d:.2}ms)\n",
            .{ friendly_name, elapsed_ms },
        );
        try Colour.reset(writer);
    } else {
        const colour = Colour.fromTestStatus(status);

        try colour.write(writer);
        try writer.print(".", .{});
        try Colour.reset(writer);
    }
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
// which conform to this naming scheme.
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
