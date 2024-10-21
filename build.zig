const debug = std.debug;
const std = @import("std");

const compile_graphviz = false;

// The public, build-time API for goku.
pub const Goku = struct {
    pub fn build(
        b: *std.Build,
        goku_dep: *std.Build.Dependency,
        site_path: std.Build.LazyPath,
        out_path: std.Build.LazyPath,
    ) *std.Build.Step.Run {
        const run_goku = b.addRunArtifact(goku_dep.artifact("goku"));
        run_goku.has_side_effects = true;

        run_goku.addDirectoryArg(site_path);
        run_goku.addArg("-o");
        run_goku.addDirectoryArg(out_path);

        return run_goku;
    }

    pub fn serve(
        b: *std.Build,
        goku_dep: *std.Build.Dependency,
        public_path: std.Build.LazyPath,
    ) *std.Build.Step.Run {
        const serve_site = b.addRunArtifact(goku_dep.artifact("serve"));
        serve_site.addDirectoryArg(public_path);
        return serve_site;
    }
};

const bundled_lucide_icons = @as([]const []const u8, &.{
    "github",
    "apple",
    "loader-pinwheel",
    "arrow-down-to-line",
});

const BuildSteps = struct {
    check: *std.Build.Step,
    coverage: *std.Build.Step,
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
        .yaml = b.dependency("yaml-src", .{}),
        .md4c = b.dependency("md4c", .{}),
        .mustach = b.dependency("mustach", .{}),
        .graphviz = b.dependency("graphviz-src", .{}),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "goku",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
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
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC();
    exe_unit_tests.root_module.addImport("c", c_mod);
    exe_unit_tests.root_module.addImport("tracy", tracy.module("tracy"));
    exe_unit_tests.root_module.addImport("clap", clap.module("clap"));
    exe_unit_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    exe_unit_tests.root_module.addImport("lucide", lucide.module("lucide"));
    exe_unit_tests.root_module.addImport("bulma", bulma.module("bulma"));
    exe_unit_tests.root_module.addImport("htmx", htmx.module("htmx"));
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
        "--include-pattern=src/",
        "--exclude-pattern=.cache/zig/",
        // todo use b.path
        "kcov-output/",
    });
    run_coverage.addArtifactArg(exe_unit_tests);
    build_steps.coverage.dependOn(&run_coverage.step);

    const exe_check = b.addExecutable(.{
        .name = "goku",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_check.linkLibC();
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

    const build_site_cmd = Goku.build(b, &this_dep_hack, b.path("site"), b.path("build"));
    if (b.args) |args| {
        build_site_cmd.addArgs(args);
    }
    build_steps.site.dependOn(&build_site_cmd.step);
    build_steps.site.dependOn(b.getInstallStep());

    const run_serve_cmd = Goku.serve(b, &this_dep_hack, b.path("build"));
    build_steps.serve.dependOn(build_steps.site);
    build_steps.serve.dependOn(&run_serve_cmd.step);
}

const BuildCModuleOptions = struct {
    yaml: *std.Build.Dependency,
    md4c: *std.Build.Dependency,
    mustach: *std.Build.Dependency,
    graphviz: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};
pub fn buildCModule(b: *std.Build, opts: BuildCModuleOptions) *std.Build.Module {
    const yaml_src = opts.yaml;
    const md4c = opts.md4c;
    const mustach = opts.mustach;
    const graphviz_src = opts.graphviz;
    const target = opts.target;
    const optimize = opts.optimize;

    const c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add(
            "c.h",
            \\#include <yaml.h>
            \\#include <md4c-html.h>
            \\#include <mustach.h>
            ++ if (compile_graphviz)
                \\#include <gvc/gvc.h>
            else
                "",
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

    {
        const wf = b.addWriteFiles();
        c.step.dependOn(&wf.step);

        _ = wf.add(
            "config.h",
            \\#define YAML_VERSION_STRING "0.2.5"
            \\#define YAML_VERSION_MAJOR 0
            \\#define YAML_VERSION_MINOR 2
            \\#define YAML_VERSION_PATCH 5
            ,
        );
        inline for (&.{
            "yaml.h",
        }) |filename| {
            _ = wf.addCopyFile(
                yaml_src.path("include/" ++ filename),
                filename,
            );
        }
        inline for (&.{
            "yaml_private.h",
        }) |filename| {
            _ = wf.addCopyFile(
                yaml_src.path("src/" ++ filename),
                filename,
            );
        }

        // TODO Not sure why I have to do both addIncludeDir (for
        // the translate_c step) and addIncludePath (for the C
        // source files) -- is there a way to get them both to
        // look in the same place?
        c.addIncludePath(yaml_src.path("include"));
        mod.addIncludePath(wf.getDirectory());

        const c_source_files = &.{
            "parser.c",
            "scanner.c",
            "reader.c",
            "api.c",
        };
        inline for (c_source_files) |filename| {
            _ = wf.addCopyFile(
                yaml_src.path("src/" ++ filename),
                filename,
            );
        }

        mod.addCSourceFiles(.{
            .root = wf.getDirectory(),
            .files = c_source_files,
            .flags = &.{
                "-std=gnu99",
                "-DHAVE_CONFIG_H",
            },
        });
    }

    if (compile_graphviz) {
        const wf = b.addWriteFiles();
        c.step.dependOn(&wf.step);

        inline for (&.{
            "gvc/gvc.h",
            "common/const.h",
            "gvc/gvcjob.h",
            "gvc/gvcint.h",
            "gvc/gvcproc.h",
            "gvc/gvconfig.h",
            "gvc/gvio.h",
            "cgraph/agxbuf.h",
            "util/alloc.h",
            "util/exit.h",
            "util/prisize_t.h",
            "cgraph/gv_ctype.h",
            "cgraph/list.h",
            "util/gv_fopen.h",
            "util/startswith.h",
            "common/types.h",
            "gvc/gvplugin.h",
            "cgraph/cghdr.h",
            "util/streq.h",
            "util/unreachable.h",
            "cgraph/node_set.h",
            "cgraph/cgraph.h",
        }) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/" ++ filename),
                filename,
            );
        }
        inline for (&.{
            "gvc.h",
            "gvcext.h",
            "gvplugin.h",
            "gvcommon.h",
        }) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/gvc/" ++ filename),
                filename,
            );
        }

        inline for (&.{
            "types.h",
            "geom.h",
            "arith.h",
            "textspan.h",
            "usershape.h",
            "color.h",
        }) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/common/" ++ filename),
                filename,
            );
        }

        inline for (&.{
            "pathgeom.h",
        }) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/pathplan/" ++ filename),
                filename,
            );
        }

        // TODO cgraph.h is included via both:
        // #include <cgraph/cgraph.h>
        // and
        // #include "cgraph.h"
        // I guess the header file doesn't have an adequate guard,
        // because I'm getting redefinition errors with my current
        // way of including header files (adding them to multiple
        // lookup locations). Seems like I'll need to revisit my
        // approach in order to successfully compile graphviz.
        inline for (&.{
            //"cgraph.h",
        }) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/cgraph/" ++ filename),
                filename,
            );
        }

        inline for (&.{
            "cdt.h",
        }) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/cdt/" ++ filename),
                filename,
            );
        }

        // TODO Not sure why I have to do both addIncludeDir (for
        // the translate_c step) and addIncludePath (for the C
        // source files) -- is there a way to get them both to
        // look in the same place?
        // TODO `getPath` is intended to be used during the make
        // phase only - is there a better way to `addIncludeDir`
        // when pointing to a dependency path?
        inline for (&.{
            "lib",
            "lib/common",
            "lib/gvc",
            "lib/pathplan",
            "lib/cgraph",
            "lib/cdt",
        }) |include_path| {
            c.addIncludePath(graphviz_src.path(include_path));
        }
        mod.addIncludePath(wf.getDirectory());

        const c_source_files = &.{
            "gvc/gvc.c",
            "gvc/gvconfig.c",
            "cgraph/attr.c",
            "cgraph/graph.c",
        };
        inline for (c_source_files) |filename| {
            _ = wf.addCopyFile(
                graphviz_src.path("lib/" ++ filename),
                filename,
            );
        }

        mod.addCSourceFiles(.{
            .root = wf.getDirectory(),
            .files = c_source_files,
            .flags = &.{},
        });
    }

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
