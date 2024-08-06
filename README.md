# Goku

Goku is a Static Site Generator written in Zig.

## Introduction

A static site generator (SSG) is typically run on some input source to produce a folder of html files, suitable for hosting on any HTTP server. Goku aims to be a SSG that can operate on a variety of input sources to generate static sites of up to hundreds of thousands of pages.

## Notice

> [!NOTE]  
> Goku is in its early stages. While more features are planned, only the bare minimum for producing a static site are currently implemented. See the notes in the [Site](#site) section of the readme for details.

## Requirements

- Officially supported Zig: `Zig 0.13.0-dev.351+64ef45eb0` (you can get it from the [Zig Releases page](https://ziglang.org/download/))

## Installation

Use Zig to build the application binary. With a shell open in this project's directory:

```
zig build -Doptimize=ReleaseSafe
```

The goku binary will be available at `zig-out/bin/goku`.

## Usage

See the [Site](#site) section of the readme for instructions on setting up your static site. Once you've set up your site, you can use goku to build it:

```
goku site -o build
```

In the above example, Goku will scan `site/pages` recursively for all `.md` files, parse their yaml frontmatter for a `slug`, and then place the built sites into the `build` folder according to each page's `slug`. It will provide a build summary with the time elapsed and the source and destination directories.

Once you've built the site, you can try previewing it on your local machine using your preferred file server. For example, if you have `python3` on your system, you can try:

```
sh -c 'cd build; python3 -m http.server'
```

## Site

To prepare a site, you must create a site folder to contain your site's configuration and content. Then, you must create a `pages` folder to house the source files for your pages:

```
mkdir site
mkdir site/pages
```

To create your first page, create the file `site/pages/home.md` with these contents:

```md
---
title: Home page
slug: /
---

# Hello, world

This is the home page.
```

Your site directory should look like this:

```
$ tree site
site
└── pages
    └── home.md

2 directories, 1 file
```

You can add any number of markdown files inside the `pages` directory to be picked up by Goku. They can be at an arbitrary depth, however you'd like to organize them; their destination in the build folder are only determined by the `slug` parameter in each page's frontmatter.

## Further Work

In its current form, Goku is very basic. There is no support for theming, custom html template, asset management, etc. If there's a feature you'd like to see, please open a GitHub issue.

## Contributing

Contributions are welcome, but I do request that if there's no open GitHub issue regarding your ideal change that you open one first! It's likely that I'm already working on the feature, so following this process helps to ensure that we're not spending double the time.

## Bug reports

If you find a bug in the software, please report it using the GitHub issue tracker for this project's repository.

