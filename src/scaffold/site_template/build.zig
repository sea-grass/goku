const std = @import("std");
const Goku = @import("goku").Goku;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const site_path = b.path(".");
    const out_path = b.path("build");

    const goku_dep = b.dependency("goku", .{
        .target = target,
        .optimize = optimize,
    });

    const site_step = b.step("site", "Build the site with Goku");
    const build_site = Goku.build(goku_dep, site_path, out_path);
    site_step.dependOn(&build_site.step);

    const serve_step = b.step("serve", "Serve the built Goku site");
    const serve_site = Goku.serve(goku_dep, out_path);
    serve_site.step.dependOn(&build_site.step);
    serve_step.dependOn(&serve_site.step);
}
