const debug = std.debug;
const std = @import("std");

pub const Goku = @import("src/Goku.zig");

const bundled_lucide_icons = @as([]const []const u8, &.{
    "github",
    "apple",
    "loader-pinwheel",
    "arrow-down-to-line",
});

const BuildSteps = struct {
    check: *std.Build.Step,
    coverage: *std.Build.Step,
    docs: *std.Build.Step,
    generate_benchmark_site: *std.Build.Step,
    run: *std.Build.Step,
    run_benchmark: *std.Build.Step,
    site: *std.Build.Step,
    serve: *std.Build.Step,
    @"test": *std.Build.Step,

    pub fn init(b: *std.Build) BuildSteps {
        return .{
            .check = b.step(
                "check",
                "Check the Zig code",
            ),
            .coverage = b.step(
                "coverage",
                "Analyze code coverage",
            ),
            .docs = b.step(
                "docs",
                "Generate source code docs",
            ),
            .generate_benchmark_site = b.step(
                "generate-benchmark",
                "Generate a site dir used to benchmark goku",
            ),
            .run = b.step(
                "run",
                "Run the app",
            ),
            .run_benchmark = b.step(
                "run-benchmark",
                "Run the benchmark",
            ),
            .site = b.step(
                "site",
                "Build the Goku site",
            ),
            .serve = b.step(
                "serve",
                "Serve the Goku site (for local previewing)",
            ),
            .@"test" = b.step(
                "test",
                "Run unit tests",
            ),
        };
    }
    pub fn deinit(self: @This()) void {
        inline for (@typeInfo(@This()).@"struct".fields) |f| {
            const step = @field(self, f.name);
            debug.assert(step.dependencies.items.len > 0);
        }
    }
};

pub const Docs = struct {
    compile: *std.Build.Step.Compile,
    serve: *std.Build.Step.Run,
    install: *std.Build.Step.InstallDir,

    pub fn fromTests(compile: *std.Build.Step.Compile) Docs {
        const b: *std.Build = compile.root_module.owner;
        const target = compile.root_module.resolved_target.?;
        const optimize = compile.root_module.optimize.?;

        const install = compile.root_module.owner.addInstallDirectory(.{
            .source_dir = compile.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs",
        });

        const exe = b.addExecutable(.{
            .name = b.fmt("serve-{s}", .{compile.name}),
            .root_source_file = b.path("src/serve.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zap", b.dependency("zap", .{}).module("zap"));

        const serve = b.addRunArtifact(exe);
        serve.addDirectoryArg(compile.getEmittedDocs());

        return .{
            .compile = compile,
            .install = install,
            .serve = serve,
        };
    }
};

pub fn build(b: *std.Build) void {
    const build_steps = BuildSteps.init(b);
    defer build_steps.deinit();

    const wasm_option = b.option(
        bool,
        "wasm",
        "Compile to webassembly (supported on e.g. wasmtime)",
    ) orelse false;
    const tracy_enable = b.option(
        bool,
        "tracy_enable",
        "Enable profiling",
    ) orelse false;

    const target = if (wasm_option) b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    }) else b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tracy = b.dependency("tracy", .{
        .target = target,
        .optimize = optimize,
        .tracy_enable = tracy_enable,
        .tracy_no_exit = true,
        .tracy_manual_lifetime = true,
    });
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const lucide = b.dependency("lucide", .{
        .icons = bundled_lucide_icons,
    });
    const bulma = b.dependency("bulma", .{});
    const htmx = b.dependency("htmx", .{});
    const zap = b.dependency("zap", .{ .target = target, .optimize = optimize });

    const c_mod = buildCModule(b, .{
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
    exe.root_module.addImport("tracy", tracy.module("tracy"));
    exe.root_module.addImport("clap", clap.module("clap"));
    exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe.root_module.addImport("lucide", lucide.module("lucide"));
    exe.root_module.addImport("bulma", bulma.module("bulma"));
    exe.root_module.addImport("htmx", htmx.module("htmx"));
    exe.linkLibrary(sqlite.artifact("sqlite"));
    if (tracy_enable) {
        exe.linkLibrary(tracy.artifact("tracy"));
        exe.linkLibCpp();
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    build_steps.run.dependOn(&run_cmd.step);

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
    exe_unit_tests.root_module.addImport("clap", clap.module("clap"));
    exe_unit_tests.root_module.addImport("htmx", htmx.module("htmx"));
    exe_unit_tests.root_module.addImport("lucide", lucide.module("lucide"));
    exe_unit_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe_unit_tests.root_module.addImport("tracy", tracy.module("tracy"));
    exe_unit_tests.root_module.addImport("zap", zap.module("zap"));
    exe_unit_tests.linkLibrary(sqlite.artifact("sqlite"));
    if (tracy_enable) {
        exe_unit_tests.linkLibrary(tracy.artifact("tracy"));
        exe_unit_tests.linkLibCpp();
    }
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
    exe_check.root_module.addImport("tracy", tracy.module("tracy"));
    exe_check.root_module.addImport("clap", clap.module("clap"));
    exe_check.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe_check.root_module.addImport("lucide", lucide.module("lucide"));
    exe_check.root_module.addImport("bulma", bulma.module("bulma"));
    exe_check.root_module.addImport("htmx", htmx.module("htmx"));
    exe_check.linkLibrary(sqlite.artifact("sqlite"));
    if (tracy_enable) {
        exe_check.linkLibrary(tracy.artifact("tracy"));
        exe_check.linkLibCpp();
    }
    build_steps.check.dependOn(&exe_check.step);

    const serve_exe = b.addExecutable(.{
        .name = "serve",
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
    });
    serve_exe.root_module.addImport("zap", zap.module("zap"));
    b.installArtifact(serve_exe);

    const serve_exe_check = b.addExecutable(.{
        .name = "serve-check",
        .root_source_file = b.path("src/serve.zig"),
        .target = target,
        .optimize = optimize,
    });
    serve_exe_check.root_module.addImport("zap", zap.module("zap"));
    build_steps.check.dependOn(&serve_exe_check.step);

    const benchmark_site = buildBenchmarkSite(b);
    const install = b.addInstallDirectory(.{
        .source_dir = benchmark_site,
        .install_dir = .prefix,
        .install_subdir = "benchmark-site",
    });
    build_steps.generate_benchmark_site.dependOn(&install.step);

    const run_benchmark_cmd = b.addRunArtifact(exe);
    run_benchmark_cmd.addDirectoryArg(benchmark_site);
    run_benchmark_cmd.addArgs(&.{ "-o", "benchmark-build" });
    build_steps.run_benchmark.dependOn(&run_benchmark_cmd.step);

    var this_dep_hack: std.Build.Dependency = .{ .builder = b };

    const build_site_cmd = Goku.build(&this_dep_hack, b.path("site"), b.path("build"));
    if (b.args) |args| {
        build_site_cmd.addArgs(args);
    }
    build_steps.site.dependOn(&build_site_cmd.step);

    const run_serve_cmd = Goku.serve(&this_dep_hack, b.path("build"));
    build_steps.serve.dependOn(build_steps.site);
    build_steps.serve.dependOn(&run_serve_cmd.step);

    const docs = Docs.fromTests(exe_unit_tests);
    build_steps.docs.dependOn(&docs.serve.step);
}

const BuildCModuleOptions = struct {
    md4c: *std.Build.Dependency,
    mustach: *std.Build.Dependency,
    quickjs: *std.Build.Dependency,
    yaml: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn buildCModule(b: *std.Build, opts: BuildCModuleOptions) *std.Build.Module {
    const md4c = opts.md4c;
    const mustach = opts.mustach;
    const quickjs = opts.quickjs;
    const yaml = opts.yaml;
    const target = opts.target;
    const optimize = opts.optimize;

    const c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("c.h",
            \\#include <yaml.h>
            \\#include <md4c-html.h>
            \\#include <mustach.h>
            \\#include <quickjs.h>
        ),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mod = c.createModule();

    c.addIncludePath(md4c.artifact("md4c").getEmittedIncludeTree());
    mod.linkLibrary(md4c.artifact("md4c"));

    c.addIncludePath(mustach.artifact("mustach").getEmittedIncludeTree());
    mod.linkLibrary(mustach.artifact("mustach"));

    c.addIncludePath(quickjs.artifact("quickjs").getEmittedIncludeTree());
    mod.linkLibrary(quickjs.artifact("quickjs"));

    c.addIncludePath(yaml.artifact("yaml").getEmittedIncludeTree());
    mod.linkLibrary(yaml.artifact("yaml"));

    return mod;
}

pub fn buildBenchmarkSite(b: *std.Build) std.Build.LazyPath {
    const wf = b.addWriteFiles();
    _ = wf.add(
        "pages/home-page.md",
        \\---
        \\id: home
        \\slug: /
        \\title: Home Page
        \\---
        \\
        \\ # Home
        \\
        \\ This is the home page.
        ,
    );
    for (0..10) |i| {
        _ = wf.add(
            b.fmt("pages/page-{d}.md", .{i}),
            b.fmt(
                \\---
                \\id: page-{d}
                \\slug: /page-{d}
                \\title: Hello, world {d}
                \\---
                \\
                \\# Hello, world {d}
                \\
                \\
                \\This is a paragraph with some **bolded** content.
                \\
                \\Check out the [home page](/).
            ,
                .{ i, i, i, i },
            ),
        );
    }
    return wf.getDirectory();
}
