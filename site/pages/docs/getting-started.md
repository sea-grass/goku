---
slug: /getting-started
title: Getting started
template: page.html
collection: docs
---

To get started with Goku, you need to be able to run it. This page describes possible project structures and their ideal use cases. Skim this page for your ideal set-up.

## Run Goku with the Zig build system

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
const Goku = @import("goku").Goku;

pub fn build(b: *std.Build) !void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});
  const goku_dep = b.dependency("goku", .{ .target = target, .optimize = optimize });
  
  const site_source_path = b.path("site");
  const site_dest_path = b.path("build");
  
  const build_site = Goku.build(b, goku_dep, site_source_path, site_dest_path);
  const build_site_step = b.step("site", "Build the site");
  build_site_step.dependOn(&build_site.step);
  
  const serve_site = Goku.serve(b, goku_dep, site_dest_path);
  const serve_site_step = b.step("serve", "Serve the site");
  serve_site_step.dependOn(&build_site.step);
  serve_site_step.dependOn(&serve_site.step);
}
```

## Run Goku as a standalone binary

Binary releases are not currently available. The recommended way of using Goku at this time is by compiling a standalone binary for your machine with Zig.

## Other ways of running Goku

Thinking of running Goku in some other way not listed here? Share your thoughts in the GitHub Issues in the Goku repo.


## Getting started with Zig

