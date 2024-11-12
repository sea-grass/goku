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
const builtin = @import("builtin");
const fmt = std.fmt;
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const std = @import("std");
const time = std.time;

const BORDER = "=" ** 80;

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
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

    fn init(allocator: mem.Allocator) !Env {
        return .{
            .verbose = try readEnv(
                bool,
                allocator,
                "TEST_VERBOSE",
            ) orelse true,
            .fail_first = try readEnv(
                bool,
                allocator,
                "TEST_VERBOSE",
            ) orelse true,
            .filter = try readEnv(
                []const u8,
                allocator,
                "TEST_FILTER",
            ),
        };
    }

    fn deinit(self: Env, allocator: mem.Allocator) void {
        if (self.filter) |filter| {
            allocator.free(filter);
        }
    }

    // If T is []const u8, caller owns the result.
    fn readEnv(comptime T: type, allocator: mem.Allocator, key: []const u8) !?T {
        switch (T) {
            []const u8, bool => {},
            else => @compileError("readEnv for T not implemented"),
        }

        const value = process.getEnvVarOwned(
            allocator,
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

        switch (T) {
            []const u8 => {
                return value;
            },
            bool => {
                defer allocator.free(value);
                return ascii.eqlIgnoreCase(value, "true");
            },
            else => unreachable,
        }
    }
};

const Printer = struct {
    out: std.fs.File.Writer,

    fn init() Printer {
        return .{
            .out = std.io.getStdErr().writer(),
        };
    }

    fn print(self: Printer, comptime format: []const u8, args: anytype) !void {
        try self.out.print(format, args);
    }

    fn status(self: Printer, s: Status, comptime format: []const u8, args: anytype) !void {
        try self.out.writeAll(switch (s) {
            .pass => "\x1b[32m",
            .fail => "\x1b[31m",
            .skip => "\x1b[33m",
            else => "",
        });
        try self.out.print(format, args);
        try self.out.writeAll("\x1b[0m");
    }
};

const SlowTracker = struct {
    max: usize,
    slowest: SlowestQueue,
    timer: time.Timer,

    const TestInfo = struct {
        elapsed_ns: u64,
        name: []const u8,

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
        var slowest = SlowestQueue.init(allocator, {});
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

    fn endTiming(self: *SlowTracker, test_name: []const u8) !u64 {
        const elapsed_ns = self.timer.lap();

        // If our queue max is 0, we don't care to track timings,
        // so we don't bother to modify the queue.
        if (self.max == 0) return elapsed_ns;

        const test_info: TestInfo = .{
            .elapsed_ns = elapsed_ns,
            .name = test_name,
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

    fn display(self: *SlowTracker, printer: Printer) !void {
        const count = self.slowest.count();
        try printer.print("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (self.slowest.removeMinOrNull()) |info| {
            const elapsed_ms = @as(f64, @floatFromInt(info.elapsed_ns)) / 1_000_000.0;
            try printer.print(
                "  {d:.2}ms\t{s}\n",
                .{ elapsed_ms, info.name },
            );
        }
    }
};

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const env = try Env.init(allocator);
    defer env.deinit(allocator);

    var slowest = try SlowTracker.init(allocator, 5);
    defer slowest.deinit();

    var pass: usize = 0;
    var fail: usize = 0;
    var skip: usize = 0;
    var leak: usize = 0;

    const printer = Printer.init();
    try printer.print("\r\x1b[0K", .{}); // beginning of line and clear to end of line

    for (builtin.test_functions) |t| {
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
            printer,
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
    const status: enum { pass, fail } = if (fail == 0)
        .pass
    else
        .fail;

    try printer.status(
        switch (status) {
            .pass => .pass,
            .fail => .fail,
        },
        "\n{d} of {d} test{s} passed\n",
        .{ pass, total_tests, if (total_tests != 1) "s" else "" },
    );

    if (skip > 0) {
        try printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }

    if (leak > 0) {
        try printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }

    try printer.print("\n", .{});
    try slowest.display(printer);
    try printer.print("\n", .{});

    posix.exit(
        switch (status) {
            .pass => 0,
            .fail => 1,
        },
    );
}

fn runTest(
    t: std.builtin.TestFn,
    env: Env,
    slowest: *SlowTracker,
    leak: *usize,
    pass: *usize,
    skip: *usize,
    fail: *usize,
    printer: Printer,
) !void {
    var status: Status = .pass;
    slowest.startTiming();

    const friendly_name = friendlyName(t.name);
    current_test = friendly_name;
    std.testing.allocator_instance = .{};
    const result = t.func();
    current_test = null;

    const elapsed_ns = try slowest.endTiming(friendly_name);

    if (std.testing.allocator_instance.deinit() == .leak) {
        leak.* += 1;
        try printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
    }

    if (result) |_| {
        pass.* += 1;
    } else |err| switch (err) {
        error.SkipZigTest => {
            skip.* += 1;
            status = .skip;
        },
        else => {
            status = .fail;
            fail.* += 1;
            try printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n{s}\n", .{ BORDER, friendly_name, @errorName(err), BORDER });
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
        try printer.status(
            status,
            "{s} ({d:.2}ms)\n",
            .{ friendly_name, elapsed_ms },
        );
    } else {
        try printer.status(status, ".", .{});
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
fn isUnnamed(t: std.builtin.TestFn) bool {
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
