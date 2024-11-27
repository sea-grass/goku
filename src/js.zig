const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const io = std.io;
const log = std.log;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

// MallocFunctions should generate a struct with allocation functions
// usable by a QuickJS runtime, backed by a Zig allocator.
// c.JSMallocState.opaque holds a pointer that we can use to access the allocator.
// TODO: I think I need to store a map of ptr to slice attrs
pub const MallocFunctions = struct {
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

    pub fn js_malloc_functions(_: *MallocFunctions) [*c]c.JSMallocFunctions {
        log.info("heree weeee gooo!", .{});
        return @constCast(@ptrCast(&MallocFunctions._js_malloc_functions));
    }

    fn malloc(state: [*c]c.JSMallocState, n: usize) callconv(.C) ?*anyopaque {
        log.info("Reeeeally?!", .{});
        const self = fromState(state);
        return mallocInner(self, n) catch null;
    }

    fn free(state: [*c]c.JSMallocState, ptr: ?*anyopaque) callconv(.C) void {
        if (ptr == null) return;
        const self = fromState(state);

        return freeInner(self, ptr) catch {
            @panic("Could not free memory");
        };
    }

    fn realloc(state: [*c]c.JSMallocState, ptr: ?*anyopaque, n: usize) callconv(.C) ?*anyopaque {
        if (ptr == null) return malloc(state, n);

        const self = fromState(state);

        return reallocInner(self, ptr, n) catch {
            @panic("Could not realloc memory");
        };
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

    fn mallocInner(self: *MallocFunctions, n: usize) !?*anyopaque {
        const slice = try self.allocator.alloc(u8, n);
        errdefer self.allocator.free(slice);

        const ptr: ?*anyopaque = @ptrCast(slice);

        try self.map.put(ptr, .{ .slice = slice });

        return ptr;
    }

    fn freeInner(self: *MallocFunctions, ptr: ?*anyopaque) !void {
        const entry = self.map.fetchRemove(ptr) orelse {
            return error.TriedToFreeUnownedMemory;
        };

        self.allocator.free(entry.value.slice);
    }

    fn reallocInner(self: *MallocFunctions, ptr: ?*anyopaque, n: usize) !?*anyopaque {
        // TODO should I fetch and only remove after success?
        const entry = self.map.fetchRemove(ptr.?) orelse {
            return error.TriedToReallocUnknownMemory;
        };

        const slice = self.allocator.realloc(entry.value.slice, n) catch {
            return null;
        };
        errdefer self.allocator.free(slice);

        const new_ptr: ?*anyopaque = @ptrCast(slice);

        try self.map.put(new_ptr, .{ .slice = slice });

        return new_ptr;
    }

    fn fromState(state: [*c]c.JSMallocState) *MallocFunctions {
        return @alignCast(@ptrCast(state.*.@"opaque".?));
    }
};

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
    // Check for memory leaks with custom malloc using testing.allocator
    var custom_malloc = MallocFunctions.init(testing.allocator);
    defer custom_malloc.deinit();

    const rt = c.JS_NewRuntime2(
        custom_malloc.js_malloc_functions(),
        &custom_malloc,
    );
    defer c.JS_FreeRuntime(rt);

    const ctx = c.JS_NewContext(rt) orelse return error.CannotAllocateJSContext;
    defer c.JS_FreeContext(ctx);

    // Add userdata to context to be able to assert our c function is called.
    var result: struct { times_called: u8 = 0, len: usize = 0 } = .{};
    c.JS_SetContextOpaque(ctx, @ptrCast(&result));

    // Define the module that will provide the import.
    {
        const mod_source = struct {
            fn init(_ctx: ?*c.JSContext, m: ?*c.JSModuleDef) callconv(.C) c_int {
                const func = c.JS_NewCFunction(_ctx, print, "print", 1);
                _ = c.JS_SetModuleExport(_ctx, m, "print", func);
                return 0;
            }

            fn print(_ctx: ?*c.JSContext, this: c.JSValueConst, argc: c_int, argv: ?*c.JSValueConst) callconv(.C) c.JSValue {
                _ = this;
                debug.assert(argc == 1);

                const str = c.JS_ToCString(_ctx, argv.?[0..1][0]);
                defer c.JS_FreeCString(_ctx, str);

                const n: *@TypeOf(result) = @alignCast(@ptrCast(c.JS_GetContextOpaque(_ctx)));

                const slice = mem.span(str);

                // Note that we don't actually print here - instead
                // we store reporting info for the following unit test
                // assertions.
                n.*.len = slice.len;
                n.*.times_called += 1;

                return .{
                    .tag = c.JS_TAG_UNDEFINED,
                    .u = .{
                        .int32 = 0,
                    },
                };
            }
        };

        const mod = c.JS_NewCModule(ctx, "mod", mod_source.init);
        _ = c.JS_AddModuleExport(ctx, mod, "print");
    }

    const prog =
        \\import { print } from "mod";
        \\var str = "Some str";
        \\str = "Hello, ";
        \\str += "world";
        \\print(str);
    ;

    const val = c.JS_Eval(ctx, prog, prog.len, "<main>", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, val);

    try testing.expectEqual(1, result.times_called);
    try testing.expectEqual("Hello, world".len, result.len);
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

/// Not implemented yet. Still figuring out how best to expose scripting engine.
///
/// Example JsPage script:
///
/// ```
/// import {
///   // Write the page output in full or in chunks
///   write,
///   // Use marker to embed page or site values within the output.
///   // This returns symbols for the writer to identify replacements -
///   // it does not provide the literal values for the script to operate on.
///   marker,
/// } from 'goku';
///
/// write(`<!doctype html><html><head>`);
/// write(`<title>${marker('title')}</title>`);
/// write(`</head><body>`);
/// write(`<div class="section">`);
/// write(`<div class="content">${marker('content')}</div>`);
/// write(`</div>`);
/// write(`</body></html>`);
/// ```
const JsPage = struct {
    ctx: *c.JSContext,
    custom_malloc: MallocFunctions,

    pub fn init(runtime: *c.JSRuntime, module_src: []const u8) !JsPage {
        const ctx = c.JS_NewContext(runtime) orelse return error.CannotAllocateJSContext;
        errdefer c.JS_FreeContext(ctx);

        const val = c.JS_Eval(ctx, module_src, module_src.len, "<main>", c.JS_EVAL_TYPE_MODULE);
        defer c.JS_FreeValue(ctx, val);

        return .{
            .ctx = ctx,
        };
    }

    pub fn deinit(self: JsPage) void {
        c.JS_FreeContext(self.ctx);
    }

    pub fn render(self: JsPage, site: @import("Site.zig"), writer: anytype) !void {
        _ = self;
        _ = site;
        _ = writer;
    }
};
