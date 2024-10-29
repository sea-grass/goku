const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

const GokuMod = struct {
    fn define(ctx: *c.JSContext) !*c.JSModuleDef {
        const mod = c.JS_NewCModule(ctx, "goku", init) orelse return error.CannotInitGokuModule;
        addExports(ctx, mod);
        return mod;
    }

    fn init(ctx: ?*c.JSContext, m: ?*c.JSModuleDef) callconv(.C) c_int {
        _ = c.JS_SetModuleExport(
            ctx,
            m,
            "print",
            c.JS_NewCFunction(
                ctx,
                print,
                "print",
                1,
            ),
        );

        return 0;
    }

    fn print(ctx: ?*c.JSContext, this: c.JSValueConst, argc: c_int, argv: ?*c.JSValueConst) callconv(.C) c.JSValue {
        _ = this;
        debug.assert(argc == 1);

        const ptr_maybe = argv.?[0..1][0];

        const str = c.JS_ToCString(ctx, ptr_maybe);
        defer c.JS_FreeCString(ctx, str);

        const stderr = io.getStdErr().writer();
        stderr.print("{s}\n", .{str}) catch unreachable;

        return .{
            .tag = c.JS_TAG_UNDEFINED,
            .u = .{
                .int32 = 0,
            },
        };
    }

    fn addExports(ctx: *c.JSContext, mod: *c.JSModuleDef) void {
        _ = c.JS_AddModuleExport(ctx, mod, "print");
    }
};

// MallocFunctions should generate a struct with allocation functions
// usable by a QuickJS runtime, backed by a Zig allocator.
// c.JSMallocState.opaque holds a pointer that we can use to access the allocator.
// TODO: I think I need to store a map of ptr to slice attrs
const MallocFunctions = struct {
    allocator: mem.Allocator,
    map: AllocMap,

    const _js_malloc_functions: c.JSMallocFunctions = .{
        .js_malloc = malloc,
        .js_free = free,
        .js_realloc = realloc,
        .js_malloc_usable_size = malloc_usable_size,
    };

    // Thanks to the following ziggit forum thread for the suggestion
    // on allocating a struct with the slice in order to access the
    // underlying slice from an opaque pointer:
    // https://ziggit.dev/t/how-to-go-from-extern-pointer-to-slice/178
    const AllocUnit = struct { slice: []u8 };
    const AllocMap = std.AutoHashMap(?*anyopaque, AllocUnit);

    pub fn init(ally: mem.Allocator) MallocFunctions {
        return .{
            .allocator = ally,
            .map = AllocMap.init(ally),
        };
    }

    // Free memory associated with the alloc map.
    // Note that it does not free memory used by the js_malloc functions,
    // since it's assumed that the JS runtime will keep track of and free
    // those itself.
    pub fn deinit(self: *MallocFunctions) void {
        self.map.deinit();
    }

    fn js_malloc_functions(self: *MallocFunctions) [*c]c.JSMallocFunctions {
        _ = self;

        return @constCast(@ptrCast(&MallocFunctions._js_malloc_functions));
    }

    fn malloc(state: [*c]c.JSMallocState, n: usize) callconv(.C) ?*anyopaque {
        const self = fromState(state);

        // TODO I can't errdefer free here because this fn doesn't return an error.
        // I need to refactor these malloc implementations to call an internal,
        // error union-returning variant in order to express memory safety better.
        const slice = self.allocator.alloc(u8, n) catch return null;
        errdefer self.allocator.free(slice);

        const ptr: ?*anyopaque = @ptrCast(slice);

        self.map.put(ptr, .{ .slice = slice }) catch {
            self.allocator.free(slice);
            return null;
        };

        return ptr;
    }

    fn free(state: [*c]c.JSMallocState, ptr: ?*anyopaque) callconv(.C) void {
        if (ptr == null) {
            return;
        }

        const self = fromState(state);
        const entry = self.map.fetchRemove(ptr) orelse {
            @panic("Tried to free unowned memory.");
        };
        const alloc_unit = entry.value;
        self.allocator.free(alloc_unit.slice);
    }

    fn realloc(state: [*c]c.JSMallocState, ptr: ?*anyopaque, n: usize) callconv(.C) ?*anyopaque {
        if (ptr == null) return malloc(state, n);

        const self = fromState(state);
        // TODO better error handling
        const entry = self.map.fetchRemove(ptr.?) orelse return null;
        // TODO better error handling
        const slice = self.allocator.realloc(
            entry.value.slice,
            n,
        ) catch return null;
        const new_ptr: ?*anyopaque = @ptrCast(slice);

        self.map.put(new_ptr, .{ .slice = slice }) catch {
            self.allocator.free(slice);
            return null;
        };

        return new_ptr;
    }

    // The man pages for `malloc_usable_size` declare that this function
    // is "is intended to only be used for diagnostics
    // and statistics."
    // Without being provided the c.JSMallocState, we are unable to lookup
    // the allocated slice in the AllocMap, therefore we cannot determine
    // the usable size.
    // This function is effectively a no-op; it always returns 0.
    fn malloc_usable_size(_: ?*const anyopaque) callconv(.C) usize {
        return 0;
    }

    fn fromState(state: [*c]c.JSMallocState) *MallocFunctions {
        return @alignCast(@ptrCast(state.*.@"opaque".?));
    }
};

fn js_goku_init(ctx: ?*c.JSContext, m: ?*c.JSModuleDef) callconv(.C) c_int {
    _ = c.JS_SetModuleExport(
        ctx,
        m,
        "exit",
        c.JS_NewCFunction(ctx, js_exit, "exit", 1),
    );

    return 0;
}

fn js_exit(ctx: ?*c.JSContext, this: c.JSValueConst, argc: c_int, argv: ?*c.JSValueConst) callconv(.C) c.JSValue {
    _ = this;
    _ = argc;

    var status: c_int = undefined;
    if (c.JS_ToInt32(ctx, &status, argv.?[0..1][0]) == 1) {
        @panic("Encountered an error trying to parse args.");
    }

    io.getStdErr().writer().print("Exit code: {d}\n", .{status}) catch @panic("Unexpected error");

    return .{
        .tag = c.JS_TAG_UNDEFINED,
        .u = .{
            .int32 = 0,
        },
    };
}

test "console not defined" {
    const rt = c.JS_NewRuntime();
    defer c.JS_FreeRuntime(rt);

    const ctx = c.JS_NewContext(rt) orelse return error.CannotAllocateJSContext;
    defer c.JS_FreeContext(ctx);

    const prog =
        \\console.log("Hello, world!");
    ;

    const val = c.JS_Eval(ctx, prog, prog.len, "<main>", 0);
    defer c.JS_FreeValue(ctx, val);

    try testing.expectEqual(
        c.JS_TAG_EXCEPTION,
        val.tag,
    );

    try expectException(
        "ReferenceError: 'console' is not defined",
        ctx,
    );
}

test "provide print" {
    var custom_malloc = MallocFunctions.init(testing.allocator);
    defer custom_malloc.deinit();

    const rt = c.JS_NewRuntime2(
        custom_malloc.js_malloc_functions(),
        &custom_malloc,
    );
    defer c.JS_FreeRuntime(rt);

    const ctx = c.JS_NewContext(rt) orelse return error.CannotAllocateJSContext;
    defer c.JS_FreeContext(ctx);

    _ = try GokuMod.define(ctx);

    const prog =
        \\import * as goku from 'goku';
        \\goku.print("Hello, world");
    ;

    const val = c.JS_Eval(ctx, prog, prog.len, "<main>", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, val);
}

fn expectException(comptime expected: []const u8, ctx: *c.JSContext) !void {
    const exception = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exception);

    const str = c.JS_ToCString(ctx, exception);
    defer c.JS_FreeCString(ctx, str);

    try testing.expectEqualStrings(
        expected,
        mem.span(str),
    );
}
