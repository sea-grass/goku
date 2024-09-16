---
slug: /docs/collection
title: Collection
template: page.html
collection: docs
---

You can add pages to a collection in Goku using the `collection` parameter. You can then make lists of pages using `collections.<name>.list` and display a link to the latest page in a collection using `collections.<name>.latest`.

#### Using `collections.<name>.list`

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

#### Using `collections.<name>.latest`

Let's say you want to advertise the latest blog article on your home page. You can generate a chunk for the latest blog page, based on its `date` parameter, like this:

```
{{& collections.blog.latest}}
```

This will result in the corresponding HTML:

```
<a href="/blog/baz">Baz</a>
```