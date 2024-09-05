---
slug: /
title: Goku
allow_html: true
template: basic.html
---

A static site generator written in Zig.

<style>
  #spinner {
    animation: spin 4s infinite linear;
    display: inline-block;
    transform-origin: center;
  }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }
</style>

<div id="spinner">

- [Docs](/docs)
- [Source code](https://github.com/sea-grass/goku)
- [Changelog](/changelog)
- [Blog](/blog)
  
</div>

## Latest blog post

{{& collections.blog.latest}}

