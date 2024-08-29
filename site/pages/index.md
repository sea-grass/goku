---
slug: /
title: Goku
allow_html: true
template: basic.html
---

<style>
  #spinner svg {
    animation: spin 4s infinite linear;
    display: inline-block;
    transform-origin: center;
  }
  @keyframes spin {
    from { transform: rotate(0deg); }
    to { transform: rotate(360deg); }
  }
</style>
  
<div id="spinner">{{&lucide.loader-pinwheel}}</div>

- [Releases](/releases)
- [Changelog](/changelog)
