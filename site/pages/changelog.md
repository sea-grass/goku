---
slug: /changelog
title: Changelog
template: basic.html
---

- [Back home](/)

## 0.0.3

This release includes some more user-friendly error messages, collections support, and additional documentation on how to build and deploy a site with Goku.

### Page Parameters

Pages now support some additional parameters.

Added:

- `collection: <name>` - Add this page to the collection named `<name>`.
- `date: <date>` - This date will be used for sorting when displaying a list of pages inside a collection.

### Improved error messages

TODO

### Collections

You can add pages to a collection in Goku using the `collection` parameter. You can then make lists of pages using `collections.<name>.list` and display a link to the latest page in a collection using `collections.<name>.latest`.

#### `collections.<name>.list`

Let's say you have a few pages in a collection named "blog" and you want to render a list of blog articles for a navigation. In a template (or a page with `allow_html: true`, you can generate a list like this:

```
{{& collections.blog.list}}
```

This will result, roughly, in the corresponding HTML:

```
<ul>
<li><a href="/blog/foo">Foo</a></li>
<li><a href="/blog/bar">Bar</a></li>
<li><a href="/blog/baz">Baz</a></li>
</ul>
```

#### `collections.<name>.latest`

Let's say you want to advertise the latest blog article on your home page. You can generate a chunk for the latest blog page, based on its `date` parameter, like this:

```
{{& collections.blog.latest}}
```

This will result in the corresponding HTML:

```
<a href="/blog/baz">Baz</a>
```

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
