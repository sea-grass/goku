---
slug: /
title: Goku
allow_html: true
template: home.html
description: A static site generator written in Zig.
---

{{& collections.test.list }}

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
  
</div>

