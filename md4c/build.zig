const debug = std.debug;
const std = @import("std");

const incl =
    \\#include <md4c-html.h>
;

const source_files = &.{
    "entity.c",
    "md4c.c",
    "md4c-html.c",
};

const compile_flags = &.{
    "-Wall",
    "-Wextra",
    "-Wshadow",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "md4c",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();

    lib.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = source_files,
        .flags = compile_flags,
    });

    // lib.addIncludePath(upstream.path("src"));
    lib.installHeadersDirectory(
        upstream.path("src"),
        "",
        .{},
    );

    const install = b.addInstallArtifact(lib, .{});

    b.getInstallStep().dependOn(&install.step);
}
