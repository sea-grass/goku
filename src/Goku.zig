//! The public, build-time API for goku.

const std = @import("std");

pub fn build(
    goku_dep: *std.Build.Dependency,
    /// The source root for the Goku site
    site_path: std.Build.LazyPath,
    // TODO should I get Goku to generate and return an out_path
    // using WriteFiles? I think for the base case this may result
    // in simpler usage, but would make more involved use cases
    // a bit more complex.
    /// The destination for the built HTML website
    out_path: std.Build.LazyPath,
) *std.Build.Step.Run {
    const b = goku_dep.builder;
    const run_goku = b.addRunArtifact(goku_dep.artifact("goku"));

    run_goku.addArg("build");
    run_goku.addDirectoryArg(site_path);
    run_goku.addArg("-o");
    run_goku.addDirectoryArg(out_path);

    return run_goku;
}

pub fn serve(
    goku_dep: *std.Build.Dependency,
    public_path: std.Build.LazyPath,
) *std.Build.Step.Run {
    const b = goku_dep.builder;
    const serve_site = b.addRunArtifact(goku_dep.artifact("serve"));

    serve_site.addDirectoryArg(public_path);

    return serve_site;
}

pub fn copyStatic(
    goku_dep: *std.Build.Dependency,
    static_path: std.Build.LazyPath,
    out_path: std.Build.LazyPath,
) *std.Build.Step.Run {
    const b = goku_dep.builder;
    const copy_static = b.addRunArtifact(goku_dep.artifact("copy_static"));

    copy_static.addArg("-from");
    copy_static.addDirectoryArg(static_path);
    copy_static.addArg("-to");
    copy_static.addDirectoryArg(out_path);

    return copy_static;
}
