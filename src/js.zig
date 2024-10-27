const c = @import("c");
const fmt = std.fmt;
const io = std.io;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

pub fn js_cfunc_def(comptime name: []const u8, comptime len: u32, comptime func: anytype) c.JSCFunctionListEntry {
    // TODO comptime assert func type
    // TODO comptime assert func len
    return .{
        .name = fmt.comptimePrint("{s}", .{name}),
        .prop_flags = c.JS_PROP_WRITABLE | c.JS_PROP_CONFIGURABLE,
        .def_type = c.JS_DEF_CFUNC,
        .magic = 0,
        .u = .{
            .func = .{
                .length = len,
                .cproto = c.JS_CFUNC_generic,
                .cfunc = .{
                    .generic = func,
                },
            },
        },
    };
}

fn js_goku_init(_ctx: ?*c.JSContext, m: ?*c.JSModuleDef) callconv(.C) c_int {
    _ = c.JS_SetModuleExport(
        _ctx,
        m,
        "exit",
        c.JS_NewCFunction(_ctx, js_exit, "exit", 1),
    );

    return 0;
}

const js_funcs: [*c]const c.JSCFunctionListEntry = @ptrCast(@alignCast(&.{
    js_cfunc_def("exit", 1, js_exit),
}));
const js_funcs_len = 1;

test "exception" {
    const rt = c.JS_NewRuntime();
    defer c.JS_FreeRuntime(rt);

    const ctx = c.JS_NewContext(rt) orelse return error.CannotAllocateJSContext;
    defer c.JS_FreeContext(ctx);

    const js_mod = c.JS_NewCModule(ctx, "goku", js_goku_init) orelse return error.CannotInitGokuModule;
    _ = c.JS_AddModuleExport(ctx, js_mod, "exit");

    const prog =
        \\import * as goku from 'goku';
        \\goku.exit(2);
    ;

    const val = c.JS_Eval(ctx, prog, prog.len, "<main>", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, val);

    // TODO perform some assertion.
    // Apparently it's an object. But with what? Because it's evaluated as a module?
    // Maybe it's the module that's returned?
    const todo = false;
    try testing.expect(todo);
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
