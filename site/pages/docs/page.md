---
slug: /docs/page
title: Page
template: page.html
collection: docs
---

A Page in Goku is represented by its metadata and content.

An author can create a Page
using markdown for the content
and yaml frontmatter for its metadata.

The Page must be placed in a file with the `.md` extension
as a descendant of the `site/pages/` directory.

For example, consider a file located at `site/pages/home.md`
with the following contents:

```
---
slug: /
title: Home page
template: home.html
---

Welcome to the home page.
```

Inside Goku, the above snippet would translate to this struct:

```
Page {
  .metadata = .{
    .slug = "/",
    .title = "Home page",
    .template = "home.html",
  },
  .content = "Welcome to the home page.",
}
```

Notice that the filename isn't part of the Page struct.
How you name and organize your pages inside the `site/pages/` directory
is up to you.

## Metadata

The Page Metadata is specified as yaml frontmatter inside the Page file.
We consider the metadata to be made up of Parameters.
Some Parameters are required, like `slug` and `title`.

### Parameters

Following is a table of all supported Parameters and their uses.

#### Required Parameters

- **`slug`** - The url where this page should be located.
- **`title`** - The title of the page.
- **`template`** - The location of the template (relative to the `site/templates/` directory) used to render this page.

#### Optional Parameters

- **`collection`** - The name of the collection to which this page belongs.
- **`date`** - A date which can be used to order page entries when rendering a collection.
- **`allow_html`** - A flag to determine whether the contents of this page should be rendered using mustache templating.
