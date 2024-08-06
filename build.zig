const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasm_option = b.option(bool, "wasm", "Compile to webassembly (supported on e.g. wasmtime)") orelse false;
    const tracy_enable = b.option(bool, "tracy_enable", "Enable profiling") orelse false;

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

    const clap = b.dependency("clap", .{ .target = target, .optimize = optimize });

    const c_mod = c: {
        const yaml_src = b.dependency("yaml-src", .{});
        const md4c_src = b.dependency("md4c-src", .{});

        const c = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add(
                "c.h",
                \\#include <yaml.h>
                \\#include <md4c-html.h>
                ,
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });

        const mod = c.createModule();

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
            // TODO `getPath` is intended to be used during the make
            // phase only - is there a better way to `addIncludeDir`
            // when pointing to a dependency path?
            c.addIncludeDir(yaml_src.path("include").getPath(b));
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

        {
            const wf = b.addWriteFiles();
            c.step.dependOn(&wf.step);

            inline for (&.{
                "entity.h",
                "md4c.h",
                "md4c-html.h",
            }) |filename| {
                _ = wf.addCopyFile(
                    md4c_src.path("src/" ++ filename),
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
            c.addIncludeDir(md4c_src.path("src").getPath(b));
            mod.addIncludePath(wf.getDirectory());

            const c_source_files = &.{
                "entity.c",
                "md4c.c",
                "md4c-html.c",
            };
            inline for (c_source_files) |filename| {
                _ = wf.addCopyFile(
                    md4c_src.path("src/" ++ filename),
                    filename,
                );
            }

            mod.addCSourceFiles(.{
                .root = wf.getDirectory(),
                .files = c_source_files,
                .flags = &.{
                    "-Wall",
                    "-Wextra",
                    "-Wshadow",
                },
            });
        }

        break :c mod;
    };

    const exe = b.addExecutable(.{
        .name = "nu-builder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.root_module.addImport("c", c_mod);
    exe.root_module.addImport("tracy", tracy.module("tracy"));
    exe.root_module.addImport("clap", clap.module("clap"));
    exe.linkLibrary(tracy.artifact("tracy"));
    if (tracy_enable) exe.linkLibCpp();
    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC();
    exe_unit_tests.root_module.addImport("c", c_mod);
    exe_unit_tests.root_module.addImport("tracy", tracy.module("tracy"));
    exe_unit_tests.root_module.addImport("clap", clap.module("clap"));
    exe_unit_tests.linkLibrary(tracy.artifact("tracy"));
    if (tracy_enable) exe_unit_tests.linkLibCpp();

    const exe_check = b.addExecutable(.{
        .name = "nu-builder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_check.linkLibC();
    exe_check.root_module.addImport("c", c_mod);
    exe_check.root_module.addImport("tracy", tracy.module("tracy"));
    exe_check.root_module.addImport("clap", clap.module("clap"));
    exe_check.linkLibrary(tracy.artifact("tracy"));
    if (tracy_enable) exe_check.linkLibCpp();

    const benchmark_site_files = b.addWriteFiles();
    _ = benchmark_site_files.add(
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
        _ = benchmark_site_files.add(
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

    const install = b.addInstallDirectory(.{
        .source_dir = benchmark_site_files.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "benchmark-site",
    });
    const benchmark_site_step = b.step("generate-benchmark", "Generate a site dir used to benchmark nu-builder.");
    benchmark_site_step.dependOn(&install.step);

    const run_benchmark_cmd = b.addRunArtifact(exe);
    run_benchmark_cmd.addDirectoryArg(benchmark_site_files.getDirectory());
    run_benchmark_cmd.addArgs(&.{ "-o", "benchmark-build" });
    const benchmark_step = b.step("run-benchmark", "Run the benchmark.");
    benchmark_step.dependOn(&run_benchmark_cmd.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const check_step = b.step("check", "Check the Zig code");
    check_step.dependOn(&exe_check.step);
}
