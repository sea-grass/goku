pub const Goku = @import("src/build/Goku.zig");

const debug = std.debug;
const std = @import("std");

const bundled_lucide_icons = @as([]const []const u8, &.{
    "github",
    "apple",
    "loader-pinwheel",
    "arrow-down-to-line",
});

pub fn build(b: *std.Build) void {
    const build_steps = .{
        .check = b.step("check", "Check the Zig code"),
        .coverage = b.step("coverage", "Analyze code coverage"),
        .docs = b.step("docs", "Generate source code docs"),
        .preview = b.step("preview", "Preview the site locally in dev mode"),
        .site = b.step("site", "Build the Goku site"),
        .@"test" = b.step("test", "Run unit tests"),
    };
    defer inline for (@typeInfo(@TypeOf(build_steps)).@"struct".fields) |f| {
        if (f.type == *std.Build.Step) {
            if (@field(build_steps, f.name).dependencies.items.len == 0) {
                @panic(b.fmt("Build step {s} has no dependencies. Consider removing it.", .{f.name}));
            }
        }
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const lucide = b.dependency("lucide", .{ .icons = bundled_lucide_icons });
    const bulma = b.dependency("bulma", .{});
    const htm = b.dependency("htm", .{});
    const vhtml = b.dependency("vhtml", .{});
    const htmx = b.dependency("htmx", .{});
    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const c_mod = CModule.build(b, .{
        .md4c = b.dependency("md4c", .{}),
        .mustach = b.dependency("mustach", .{}),
        .quickjs = b.dependency("quickjs", .{}),
        .yaml = b.dependency("yaml", .{}),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "goku",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("c", c_mod);
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe.root_module.addImport("lucide", lucide.module("lucide"));
    exe.root_module.addImport("bulma", bulma.module("bulma"));
    exe.root_module.addImport("htmx", htmx.module("htmx"));
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe.root_module.addImport("htm", htm.module("htm"));
    exe.root_module.addImport("vhtml", vhtml.module("vhtml"));
    exe.linkLibrary(sqlite.artifact("sqlite"));
    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        // We provide a name to the unit tests so the generated
        // docs will use it for the namespace.
        .name = "goku",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        //.test_runner = b.dependency("custom-test-runner", .{}).path("src/test_runner.zig"),
    });
    exe_unit_tests.root_module.addImport("bulma", bulma.module("bulma"));
    exe_unit_tests.root_module.addImport("c", c_mod);
    exe_unit_tests.root_module.addImport("htmx", htmx.module("htmx"));
    exe_unit_tests.root_module.addImport("lucide", lucide.module("lucide"));
    exe_unit_tests.root_module.addImport("htm", htm.module("htm"));
    exe_unit_tests.root_module.addImport("vhtml", vhtml.module("vhtml"));
    exe_unit_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe_unit_tests.root_module.addImport("httpz", httpz.module("httpz"));
    exe_unit_tests.linkLibrary(sqlite.artifact("sqlite"));
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    build_steps.@"test".dependOn(&run_exe_unit_tests.step);

    const run_coverage = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-pattern=src/,modules/",
        "--exclude-pattern=.cache/zig/,test_runner.zig",
    });
    run_coverage.addDirectoryArg(b.path("kcov-output/"));
    run_coverage.addArtifactArg(exe_unit_tests);
    build_steps.coverage.dependOn(&run_coverage.step);

    const exe_check = b.addExecutable(.{
        .name = "goku",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_check.root_module.addImport("c", c_mod);
    exe_check.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe_check.root_module.addImport("lucide", lucide.module("lucide"));
    exe_check.root_module.addImport("bulma", bulma.module("bulma"));
    exe_check.root_module.addImport("htmx", htmx.module("htmx"));
    exe_check.linkLibrary(sqlite.artifact("sqlite"));
    build_steps.check.dependOn(&exe_check.step);

    var this_dep_hack: std.Build.Dependency = .{ .builder = b };

    const build_site_cmd = Goku.build(&this_dep_hack, b.path("site"), b.path("build"));
    if (b.args) |args| {
        build_site_cmd.addArgs(args);
    }
    build_steps.site.dependOn(&build_site_cmd.step);

    const docs = Docs.fromTests(exe_unit_tests);
    build_steps.docs.dependOn(&docs.serve.step);

    const run_preview_cmd = Goku.preview(&this_dep_hack, b.path("site"), b.path("build"));
    build_steps.preview.dependOn(&run_preview_cmd.step);

    const copy_static = b.addExecutable(.{
        .name = "copy_static",
        .root_source_file = b.path("src/copy_static.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(copy_static);
}

pub const Docs = struct {
    compile: *std.Build.Step.Compile,
    serve: *std.Build.Step.Run,
    install: *std.Build.Step.InstallDir,

    pub fn fromTests(compile: *std.Build.Step.Compile) Docs {
        const b: *std.Build = compile.root_module.owner;
        const target = compile.root_module.resolved_target.?;

        const serve_dep = b.dependency("serve", .{
            .target = target,
            .optimize = .ReleaseSafe,
        });

        const install = compile.root_module.owner.addInstallDirectory(.{
            .source_dir = compile.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const serve = b.addRunArtifact(serve_dep.artifact("serve"));
        serve.addDirectoryArg(compile.getEmittedDocs());

        return .{
            .compile = compile,
            .install = install,
            .serve = serve,
        };
    }
};

const CModule = struct {
    const header_bytes =
        \\#include <md4c-html.h>
        \\#include <mustach.h>
        \\#include <quickjs.h>
        \\#include <quickjs-libc.h>
        \\#include <yaml.h>
    ;

    pub const Options = struct {
        md4c: *std.Build.Dependency,
        mustach: *std.Build.Dependency,
        quickjs: *std.Build.Dependency,
        yaml: *std.Build.Dependency,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn build(b: *std.Build, opts: Options) *std.Build.Module {
        const c = translateC(b, opts);
        const mod = createModule(c, opts);
        return mod;
    }

    fn translateC(b: *std.Build, opts: Options) *std.Build.Step.TranslateC {
        const header_file = b.addWriteFiles().add("c.h", header_bytes);
        const c = b.addTranslateC(.{
            .root_source_file = header_file,
            .target = opts.target,
            .optimize = opts.optimize,
            .link_libc = true,
        });
        c.addIncludePath(opts.md4c.artifact("md4c").getEmittedIncludeTree());
        c.addIncludePath(opts.mustach.artifact("mustach").getEmittedIncludeTree());
        c.addIncludePath(opts.quickjs.artifact("quickjs").getEmittedIncludeTree());
        c.addIncludePath(opts.yaml.artifact("yaml").getEmittedIncludeTree());
        return c;
    }

    fn createModule(c: *std.Build.Step.TranslateC, opts: Options) *std.Build.Module {
        const mod = c.createModule();
        mod.linkLibrary(opts.md4c.artifact("md4c"));
        mod.linkLibrary(opts.mustach.artifact("mustach"));
        mod.linkLibrary(opts.quickjs.artifact("quickjs"));
        mod.linkLibrary(opts.yaml.artifact("yaml"));
        return mod;
    }
};
