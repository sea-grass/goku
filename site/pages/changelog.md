---
slug: /changelog
title: Changelog
template: page.html
---

## 0.0.7 (in progress)

- Goku CLI subcommands `goku init`, `goku build`
- Updated to zig `0.14.0-dev.2628+5b5c60f43`

## 0.0.6

This release is a quick follow-up to the previous release to fix a bug with the theme shortcodes.

### Shortcodes

- `{{& theme.head }}` now correctly references theme assets according to the `url_prefix`, if provided.

## 0.0.5

This PR contains many changes that are under the hood to support future features. User-facing changes include a more recent supported Zig version, updates to page parameters, more informative error messages, updates to shortcodes, and improvements to the markdown renderer.

### Updated Zig version

The officially supported Zig version is now Zig `0.14.0-dev.1911+3bf89f55c`. You must upgrade to at least this Zig version when you upgrade to Goku 0.0.5.

### Page Parameters

- `template` is now a required parameter

### More informative error messages

Prior to v0.0.5, Goku would print unhelpful errors, for example `FileNotFound` when a template that a page references is missing. Now Goku does a better job at anticipating these errors and suggesting some potential fixes in some cases.

Error reporting was improved for these cases:

- If pages dir is missing, suggests to create it
- If templates dir is missing, suggests to create it
- If required frontmatter fields slug, title, or template are missing,
  prints specific message
- If a page references a non-existent template, an informative error is
  printed
- If a template is empty, an informative error is printed

### Shortcodes

- `{{& collections.*.list}}` now sorts entries by date descending then by title ascending. If the entry has a date, it is printed alongside the title in the rendered html.

### Markdown renderer

Goku uses `md4c` for its markdown rendering, which provides a callback-style interface for customizing how the document is processed. Markdown features have been implemented as required for the goku site, which means that it doesn't yet fully render all possible markdown.

In this PR, Goku now properly renders inline `code` and `strong` content in markdown content.

If you need more support for other markdown features, feel free to open an issue in this repository. Better yet, check out `src/markdown.zig` and open a PR with your changes.

## 0.0.4

This release updates the officially supported Zig version, adds some features to improve the experience of building and previewing Goku sites, automates some of the work for supporting alternate site roots, and includes some behind-the-scenes changes to support more advanced features and to pave the way for user-defined themes.

### Updated Zig version

The officially supported Zig version is now Zig `0.14.0-dev.1710+8ee52f99c`. You must upgrade to at least this Zig version when you upgrade to Goku 0.0.4.

### Getting started

#### build.zig

Goku now exposes a build-time API. To learn how to use it, check out [Getting Started](/getting-started) in the docs.

Briefly, you can use it in your build.zig like this:

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

### Themes

Goku does not yet support user-defined themes, but some shortcodes (`{{& theme.head}}` and `{{& theme.body}}`) have been added to make the transition to themes smoother once they are supported.

Previously, users had to include `bulma.css` and `htmx.js` to their templates manually. The suggested migration path is to replace these instances with the shortcodes.

### Shortcodes

Some shortcodes were added in this release.

- `{{& theme.head}}` - Render the theme's assets and metadata (typically inside `<head>` in your template)
- `{{& theme.body}}` - Render the theme's scripts (typically right before the end of `<body>` in your template)

### Site root

This release simplifies the usage of site_root. When rendering markdown pages, Goku now automatically prefixes sitewide urls with the url prefix supplied at build-time.

If your site is hosted at some url path that is not the root (e.g. if your Goku site root is at `http://example.com/blog`) then you needed to do two things: set the url prefix when building your site, and prefix all links in your content with `{{site_root}}`. Now, you don't need to prefix your links in your content at all.

Suggested migration path is to remove `{{site_root}}` from your pages. If your pages only had the `allow_html: true` parameter because of `site_root` usage, you can remove it.

Note that templates still require the usage of `{{site_root}}` (since the automatic insertion of `site_root` only occurs during markdown rendering).

## 0.0.3

This release includes basic support for collections (a way to group pages in order to link to and search through them), improvements for published sites at subpaths, and some UX improvements at when building a Goku site, in the form of more helpful error messages.

### Page Parameters

Pages now support some additional parameters.

Added:

- `collection: <name>` - Add this page to the collection named `<name>`.
- `date: <date>` - This date will be used for sorting when displaying a list of pages inside a collection.
- `description: <string>` - An optional piece of metadata that may be used inside of a template.

### Site root

If you want to publish your site as the subpath of some domain, you need to let Goku know where the root of the built site will live, in order for it to produce correct links among assets and pages.

To use this feature, you need to do two things. 1) You need to provide the url prefix while building your site; and 2) You need to use the `{{site_root}}` shortcode wherever you create links or assets. (Note that `site_root` is automatically taken into account in shortcodes such as `collections.<name>.list`.)

When building, you can specify the site root with the `-p` (or `--prefix`) argument:

```shell-session
$ goku site -o build -p my-site
```

Then, the site_root will be available to shortcodes, templates, and pages.

Note that all page slugs are always relative to the site root.


### Bug fixes

- Fixed issue where an absolute build path would cause the program to crash

### Improved error messages

TODO

### Collections

You can add a Page to a Collection using the `collection` page parameter. This allows you to group pages for ordering and viewing. See the docs for more information.

### Shortcodes

In an effort to use standard lingo to communicate about Goku's features, a Shortcode is an identifier or pattern that corresponds to some data retrieval/html rendering within a template.

Pre-0.0.3, these shortcodes were available:

- `{{& content}}` - Render the page content (i.e. the HTML generated from the page markdown content).
- `{{title}}` - Render the page title, specified by the page parameter `title`.
- `{{& lucide.<icon name>}}` - Embed the SVG for the corresponding icon in the lucide icon library.

In this version, these shortcodes were added:

- `{{& meta}}` - Render some of the page parameters as tags.
- `{{& collections.<collection name>.list}}` - Render a list of links for all of the pages in the corresponding collection.
-  `{{& collections.<collection name>.latest}}` - Render a link to the page in the corresponding collection with the latest date (based on its frontmatter `date` parameter).
- `{{site_root}}` - Use in conjunction with the `--prefix` command line argument to create links relative to your the site root.

##

### Theming

#### Added HTMX

Goku now includes `htmx` in addition to `bulma` to every built site.

#### Default theme

Note that Goku doesn't necessarily support the concept of "themes" yet. The "default theme" could be considered to be the combination of shortcodes, UI libraries (lucide, htmx, bulma), and templates that are used in a site. The choice of shortcodes and UI libraries aren't customizable at this stage. On the other hand, templates must be entirely user-defined. So, you can make use of the "default theme" by referencing the templates for Goku's own site (see the source code).


## 0.0.2

- Mustache templates are now supported by Goku (using the [mustach](https://github.com/RekGRpth/mustach) library)
- A `site` folder must now contain a `templates` directory with at least one template
- A page in `site/pages` must now contain a `template: path/to/template.html` frontmatter, which resolves to a path within the site's Templates directory (e.g. resolves to `site/templates/path/to/template.html`)
- A page may optionally be parsed by the template engine itself by specifying the `allow_html: true` frontmatter.
- [Bulma.css](https://bulma.io/) is now added to a site's output directory automatically. You can reference it in your templates at the url `/bulma.css`.
- [Lucide](https://lucide.dev/) icons are available to use within your templates. For example, you can insert `{{&lucide.sailboat}}` to embed the icon in your template. Note that you can also use Lucide icons in your pages if you add `allow_html: true`.

This release also includes some internal changes, like the use of SQLite to index the site before building.

## 0.0.1

- Initial release
