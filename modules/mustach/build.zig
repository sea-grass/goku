const debug = std.debug;
const std = @import("std");

const BuildCModuleOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    mustach: *std.Build.Step.Compile,
};

pub fn buildCModule(b: *std.Build, opts: BuildCModuleOptions) *std.Build.Module {
    const mustach = opts.mustach;
    const target = opts.target;
    const optimize = opts.optimize;

    const c = b.addTranslateC(.{
        .root_source_file = b.addWriteFiles().add("c.h",
            \\#include <mustach.h>
        ),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const mod = c.createModule();

    c.addIncludePath(mustach.getEmittedIncludeTree());
    mod.linkLibrary(mustach);

    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "mustach",
        .target = target,
        .optimize = optimize,
    });

    lib.linkLibC();

    lib.addCSourceFiles(.{
        .root = upstream.path("."),
        .files = source_files,
        .flags = compile_flags,
    });

    lib.installHeadersDirectory(
        upstream.path("."),
        "",
        .{},
    );

    const install = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install.step);

    const c_mod = buildCModule(b, .{
        .target = target,
        .optimize = optimize,
        .mustach = lib,
    });

    const module = b.addModule("mustach", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/mustach.zig"),
    });

    module.addImport("c", c_mod);
    module.linkLibrary(lib);

    const @"test" = b.addTest(.{
        .root_source_file = b.path("src/mustach.zig"),
        .target = target,
        .optimize = optimize,
    });

    @"test".root_module.addImport("c", c_mod);
    @"test".linkLibrary(lib);

    const test_step = b.step("test", "Run tests");

    const run_test = b.addRunArtifact(@"test");
    test_step.dependOn(&run_test.step);
}

const source_files = &.{
    "mustach.c",
    "mustach2.c",
    "mini-mustach.c",
    "mustach-helpers.c",
    "mustach-wrap.c",
};

const compile_flags = &.{};
