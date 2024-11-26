---
slug: /getting-started
title: Getting started
template: page.html
collection: docs
---

To get started with Goku, you need to be able to run it. This page describes possible project structures and their ideal use cases. Skim this page for your ideal set-up.

## Run Goku with the Zig build system

Prerequisites: A working Zig compiler (minimum version 0.14.0)

1. Use `goku init` to scaffold a new Goku site
2. Run `zig build site` to build the site
3. Run `zig build serve` to preview the site locally

```shell-session
$ goku init my-site
info(goku): init (my-site)
info(goku): Site scaffolded at (my-site).
$ tree my-site
my-site
├── build.zig
├── build.zig.zon
├── pages
│   └── index.md
└── templates
    └── page.html
$ cd my-site
$ zig build site
info(goku): mode Debug
info(goku): Goku Build
info(goku): Site Root: /home/user/code/my-site
info(goku): Out Dir: /home/user/code/my-site/build
debug(goku): Discovered template count 1
debug(site): rendering (Home page)[/]
info(goku): Elapsed: 3ms
$ tree build
build
├── _sitemap.html
├── bulma.css
├── htmx.js
└── index.html

1 directory, 4 files
$ zig build serve
info(goku): mode Debug
info(goku): Goku Build
info(goku): Site Root: /home/user/code/my-site
info(goku): Out Dir: /home/user/code/my-site/build
debug(goku): Discovered template count 1
debug(site): rendering (Home page)[/]
info(goku): Elapsed: 3ms
INFO: Listening on port 3000
info(serve): Running at http://localhost:3000
INFO: Server is running 1 worker X 1 thread with facil.io 0.7.4 (kqueue)
* Detected capacity: 10224 open file limit
* Root pid: 10488
* Press ^C to stop
```

## Run Goku as a standalone binary

Binary releases are not currently available. The recommended way of using Goku at this time is by compiling a standalone binary for your machine with Zig.

## Other ways of running Goku

Thinking of running Goku in some other way not listed here? Share your thoughts in the GitHub Issues in the Goku repo.

