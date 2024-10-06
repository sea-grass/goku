---
slug: /getting-started
title: Getting started
template: page.html
collection: docs
---

## Getting started with Zig

Prerequisites: A working Zig compiler (minimum version 0.13.0)

1. Create a Zig project
2. Add Goku to your dependencies in build.zig.zon
3. Create a minimal goku site (pages/index.md and templates/page.html)
4. Create a run step in your build.zig to use Goku to build your site

### 1. Create a Zig project

You can use `zig init` to create a Zig project if you wish, but all you really need to do is create minimal build.zig and build.zig.zon files.

### 2. Add Goku to your dependencies

This will allow the Zig build system to locate Goku.

### 3. Create a minimal Goku site

Create these files.

#### pages/index.md

**pages/index.md**

```
---
slug: /
template: page.html
title: Home page
---

This is the home page.
```

#### templates/page.html

**templates/page.html**

```
<!doctype html><html><head>
<title>{{title}}</title>
{{& theme.head}}
</head>
<body>
<div class="container">
<div class="section">
<div class="title">{{title}}</div>
<div class="content">{{& content}}</div>
{{& theme.body}}
</body>
</html>
```

### 4. Create a run step in your build.zig

Your build.zig should look like this:

```
const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const goku = b.dependency("goku", .{ .target = target, .optimize = optimize });

    const run_goku = b.addRunArtifact(goku.artifact("goku"));
    run_goku.addDirectoryArg(b.path("."));
    run_goku.addArg("-o");
    run_goku.addDirectoryArg(b.path("build"));

    const site_step = b.step(
        "site",
        "Build the site with Goku",
    );
    site_step.dependOn(&run_goku.step);
}
```
