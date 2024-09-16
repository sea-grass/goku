---
slug: /docs/page
title: Page
template: page.html
collection: docs
---

## Overview

A Page inside Goku looks like this:

```
.{
  .markdown = .{
    // Required
    .slug = "/",
    .content = "Welcome to the home page."
    // Optional
    .title = "Home page",
    .template = "home.html",
  },
}
```

Goku is able to parse the yaml frontmatter and render the markdown content.

You can create the same page in your site by creating a file in your site's `pages` folder:

```
---
slug: /
title: Home page
template: home.html
---

Welcome to the home page.
```

## Simplifying unique pages

Goku performs multiple render passes on your content: first, a template render, using mustache rendering, then a markdown render. This way, you can use all of mustache inside of your pages. When pages are unique, there's no need to create a shared template and split the content between page and template:

```
---
slug: /
title: Home page
---

<div class="hero">
  {{ title }}
</div>

Welcome to the home page.
```


> :warning: Note: Goku only supports markdown with yaml frontmatter at this time. As the needs arise, Goku plans to support other page sources as well.


