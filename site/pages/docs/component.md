---
slug: /docs/component
title: Component
template: page.html
collection: docs
---

A component in Goku is used as a [shortcode](/docs/shortcode) in either a [page](/docs/page) or a [template](/docs/template).

A component is a javascript module whose exports satisfy the component API.

The component API resembles this Typescript type:

```
{
  // Produce an HTML string to be injected at the point of usage.
  render: () => string;
  // Produce a JS string to be bundled in a script on a page where
  // the component is used.
  script?: () => string;
  // Produce a CSS string to be bundled in a script on a page where
  // the component is used.
  style?: () => string;
}
```
