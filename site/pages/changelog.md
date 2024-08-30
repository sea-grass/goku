---
slug: /changelog
title: Changelog
template: page.html
---

- [Back home](/goku)

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
