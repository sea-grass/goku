---
slug: /docs/site
title: Site
template: docs.html
collection: docs
---

The source for a Goku website is known as the Site. In short, a Site is a directory that is the common root for Pages and Templates.

## Quickstart

A Goku site may look like this:

```
site
- pages
  - index.md
- templates
  - basic.html

3 directories, 2 files
```

Let's create this site by running the following commands:

```sh
$ mkdir site

$ mkdir site/templates

$ cat >site/templates/basic.html <<EOF
<!doctype html>
<html>
  <head>
    <title>{{title}}</title>
    <link rel="stylesheet" lang="text/css" href="/bulma.css" />
    <meta name="viewport" content="width=device-width, initial-scale=1">
  </head>
  <body>
    <div class="section">
      <div class="container">
        <div class="content">
          {{& content}}
        </div>
      </div>
    </div>
  </body>
</html>
EOF

$ mkdir site/pages

$ cat >site/pages/index.md <<EOF
---
slug: /
title: Home page
template: basic.html
---

Hello, world.
EOF
```

Let's break down each of these commands.

`mkdir site` creates the `site` directory.

`mkdir site/templates` creates the `site/templates` directory.

The line starting with `cat >site/templates/basic.html` will create the file `site/templates/basic.html` with the contents between each of the `EOF` tokens.

`mkdir site/pages` creates the `site/pages` directory.

The line starting with `cat >site/pages/index.md` will create the file `site/pages/index.md` with the contents between the EOF tokens.

## Adding more pages

To add more pages to your site, all you need to do is create a `.md` file somewhere in `site/pages` with at least the `slug`, `title`, and `template` parameters.

## Adding more templates

Similar to the method to add new pages to your site, you create new templates by placing a `.html` file in your `site/templates` folder.
