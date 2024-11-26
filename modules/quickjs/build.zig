const debug = std.debug;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "quickjs",
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
}

const source_files = &.{
    "cutils.c",
    "libbf.c",
    "libregexp.c",
    "libunicode.c",
    "quickjs.c",
};

const compile_flags = &.{
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
    "-fwrapv",
    "-D_GNU_SOURCE",
    // TODO specify this in a config header
    "-DCONFIG_VERSION=\"2024-02-14\"",
    // TODO specify this in a config header
    "-DCONFIG_BIGNUM",
};
