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

    const exe = b.addExecutable(.{
        .name = "nu-builder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    yaml.addCSourceFiles(b, exe, "lib/yaml", target, optimize);
    exe.root_module.addImport("tracy", tracy.module("tracy"));
    exe.linkLibrary(tracy.artifact("tracy"));
    exe.linkLibCpp();
    b.installArtifact(exe);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.linkLibC();
    yaml.addCSourceFiles(b, exe_unit_tests, "lib/yaml", target, optimize);
    exe_unit_tests.root_module.addImport("tracy", tracy.module("tracy"));
    exe_unit_tests.linkLibrary(tracy.artifact("tracy"));
    exe_unit_tests.linkLibCpp();

    const exe_check = b.addExecutable(.{
        .name = "nu-builder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_check.linkLibC();
    yaml.addCSourceFiles(b, exe_check, "lib/yaml", target, optimize);
    exe_check.root_module.addImport("tracy", tracy.module("tracy"));
    exe_check.linkLibrary(tracy.artifact("tracy"));
    exe_check.linkLibCpp();

    const benchmark_site_files = b.addWriteFiles();
    for (0..50_000) |i| {
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

const yaml = struct {
    pub fn addCSourceFiles(b: *std.Build, compile: *std.Build.Step.Compile, comptime lib_root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
        const wf = b.addWriteFiles();

        _ = wf.add(
            "config.h",
            \\#define YAML_VERSION_STRING "0.2.5"
            \\#define YAML_VERSION_MAJOR 0
            \\#define YAML_VERSION_MINOR 2
            \\#define YAML_VERSION_PATCH 5
            ,
        );
        inline for (&.{
            "yaml_private.h",
        }) |filename| {
            _ = wf.addCopyFile(
                b.path(lib_root ++ "/src/" ++ filename),
                filename,
            );
        }
        const c_source_files = &.{
            "parser.c",
            "scanner.c",
            "reader.c",
            "api.c",
        };
        inline for (c_source_files) |filename| {
            _ = wf.addCopyFile(
                b.path(lib_root ++ "/src/" ++ filename),
                filename,
            );
        }

        const c = b.addTranslateC(.{
            .root_source_file = wf.add(
                "c.h",
                \\#include <yaml.h>
                ,
            ),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // TODO Not sure why I have to do both addIncludeDir (for
        // the translate_c step) and addIncludePath (for the C
        // source files) -- is there a way to get them both to
        // look in the same place?
        c.addIncludeDir(lib_root ++ "/include");

        const mod = c.createModule();
        mod.addIncludePath(b.path(lib_root ++ "/include"));
        mod.addCSourceFiles(.{
            .root = wf.getDirectory(),
            .files = c_source_files,
            .flags = &.{
                "-std=gnu99",
                "-DHAVE_CONFIG_H",
            },
        });

        compile.root_module.addImport("c", mod);
    }
};
