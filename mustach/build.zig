const debug = std.debug;
const std = @import("std");

const source_files = &.{
    "mustach.c",
    "mustach2.c",
    "mini-mustach.c",
    "mustach-helpers.c",
    "mustach-wrap.c",
};

const compile_flags = &.{};

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

    // lib.addIncludePath(upstream.path("src"));
    lib.installHeadersDirectory(
        upstream.path("."),
        "",
        .{},
    );

    const install = b.addInstallArtifact(lib, .{});

    b.getInstallStep().dependOn(&install.step);
}
