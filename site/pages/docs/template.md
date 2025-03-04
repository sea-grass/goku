---
slug: /docs/template
title: Template
template: page.html
collection: docs
---

A template in Goku is typically an HTML document with Mustache directives, which are referred to within Goku as [shortcodes](/docs/shortcode).

Every [page](/docs/page) in a Goku site is required to reference a template. When the page is rendered, its content will be injected into the template through the `{{& content }}` shortcode.

> If you forget to include the `content` shortcode in your template, the page content won't be rendered at all! Sometimes, this may be what you want.
