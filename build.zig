const std = @import("std");

fn addYamlSourceFiles(b: *std.Build, compile: *std.Build.Step.Compile, comptime lib_root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
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

pub fn build(b: *std.Build) void {
    const wasm_option = b.option(bool, "wasm", "Compile to webassembly (supported on e.g. wasmtime)") orelse false;

    const target = if (wasm_option) b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    }) else b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nu-builder",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    addYamlSourceFiles(b, exe, "lib/yaml", target, optimize);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
