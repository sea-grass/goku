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
        const quickjs_src = b.dependency("quickjs-src", .{});

        const c = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add(
                "c.h",
                \\#include <yaml.h>
                \\#include <quickjs.h>
                \\#include <quickjs-libc.h>
                \\#include <remark-bin.h>
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
                "quickjs-libc.h",
                "libregexp-opcode.h",
                "libunicode-table.h",
                "quickjs-opcode.h",
                "quickjs-atom.h",
                "libbf.h",
                "libunicode.h",
                "libregexp.h",
                "list.h",
                "cutils.h",
                "quickjs.h",
            }) |filename| {
                _ = wf.addCopyFile(
                    quickjs_src.path(filename),
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
            c.addIncludeDir(quickjs_src.path(".").getPath(b));
            mod.addIncludePath(wf.getDirectory());

            const c_source_files = &.{
                "quickjs-libc.c",
                "libbf.c",
                "libunicode.c",
                "libregexp.c",
                "cutils.c",
                "quickjs.c",
            };
            inline for (c_source_files) |filename| {
                _ = wf.addCopyFile(
                    quickjs_src.path(filename),
                    filename,
                );
            }

            mod.addCSourceFiles(.{
                .root = wf.getDirectory(),
                .files = c_source_files,
                .flags = &.{
                    "-g",
                    "-Wall",
                    "-Wextra",
                    "-Wno-sign-compare",
                    "-Wno-missing-field-initializers",
                    "-Wundef",
                    "-Wuninitialized",
                    "-Wunused",
                    "-Wno-unused-parameter",
                    "-Wwrite-strings",
                    "-Wchar-subscripts",
                    "-funsigned-char",
                    "-Wno-array-bounds",
                    "-Wno-format-truncation",
                    "-Werror",
                    "-DCONFIG_VERSION=\"2024-02-14\"",
                    "-DCONFIG_BIGNUM",
                },
            });
        }

        {
            const wf = b.addWriteFiles();
            c.step.dependOn(&wf.step);

            inline for (&.{
                "lib/remark-bin.h",
            }) |filename| {
                _ = wf.add(filename, @embedFile(filename));
            }

            c.addIncludeDir("lib");
            mod.addIncludePath(wf.getDirectory());
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
    for (0..1_000) |i| {
        _ = benchmark_site_files.add(
            b.fmt("pages/page-{d}.md", .{i}),
            b.fmt(
                \\---
                \\id: page-{d}
                \\slug: /page-{d}
                \\---
                \\<p>Page content</p>
            ,
                .{ i, i },
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
