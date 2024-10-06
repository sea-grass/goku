---
slug: /changelog
title: Changelog
template: page.html
---

## 0.0.4 (in-progress)

(tbd)

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
