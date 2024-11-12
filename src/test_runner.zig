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

const builtin = @import("builtin");
const heap = std.heap;
const math = std.math;
const mem = std.mem;
const std = @import("std");
const time = std.time;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;

pub fn main() !void {
    var buf: [8192]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const env = Env.init(allocator);
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
        if (isSetup(t)) {
            try runSetup(t, printer);
        }
    }

    for (builtin.test_functions) |t| {
        if (isSetup(t) or isTeardown(t)) {
            continue;
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

    for (builtin.test_functions) |t| {
        if (isTeardown(t)) {
            try runTeardown(t, printer);
        }
    }

    const total_tests = pass + fail;
    const status = if (fail == 0) Status.pass else Status.fail;
    try printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
    if (skip > 0) {
        try printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
    }
    if (leak > 0) {
        try printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
    }
    try printer.print("\n", .{});
    try slowest.display(printer);
    try printer.print("\n", .{});
    std.posix.exit(if (fail == 0) 0 else 1);
}

fn friendlyName(name: []const u8) []const u8 {
    var it = mem.splitScalar(u8, name, '.');
    while (it.next()) |value| {
        if (mem.eql(u8, value, "test")) {
            const rest = it.rest();
            return if (rest.len > 0) rest else name;
        }
    }
    return name;
}

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

const Status = enum {
    pass,
    fail,
    skip,
    text,
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

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,

    fn init(allocator: mem.Allocator) Env {
        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .filter = readEnv(allocator, "TEST_FILTER"),
        };
    }

    fn deinit(self: Env, allocator: mem.Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(allocator: mem.Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: mem.Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }
};

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (current_test) |ct| {
        std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n", .{ BORDER, ct });

        if (error_return_trace) |trace| {
            if (ret_addr) |addr| {
                std.debug.print("{s}@{d}\n{any}\n", .{ msg, addr, trace });
            } else {
                std.debug.print("{s}@null\n{any}\n", .{ msg, trace });
            }
        } else {
            if (ret_addr) |addr| {
                std.debug.print("{s}@{d}\n(no trace)\n", .{ msg, addr });
            } else {
                std.debug.print("{s}@null\n(no trace)\n", .{msg});
            }
        }

        std.debug.print("{s}\x1b[0m\n", .{BORDER});
    }

    //std.debug.defaultPanic(msg, error_return_trace, ret_addr);
    @panic(msg);
}

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return mem.endsWith(
        u8,
        t.name,
        "tests:beforeAll",
    );
}

fn runSetup(t: std.builtin.TestFn, printer: Printer) !void {
    current_test = friendlyName(t.name);
    t.func() catch |err| {
        try printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
        return err;
    };
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
    var status = Status.pass;
    slowest.startTiming();

    const is_unnamed_test = isUnnamed(t);
    if (env.filter) |f| {
        if (!is_unnamed_test and mem.indexOf(u8, t.name, f) == null) {
            return;
        }
    }

    const friendly_name = friendlyName(t.name);
    current_test = friendly_name;
    std.testing.allocator_instance = .{};
    const result = t.func();
    current_test = null;

    if (is_unnamed_test) {
        return;
    }

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

fn runTeardown(t: std.builtin.TestFn, printer: Printer) !void {
    current_test = friendlyName(t.name);
    t.func() catch |err| {
        try printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
        return err;
    };
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return mem.endsWith(
        u8,
        t.name,
        "tests:afterAll",
    );
}
