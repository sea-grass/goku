# vimwiki-ghpages-template

This template makes it easy to get started with vimwiki and publishing your wiki to GitHub pages!

## Prerequisites

- [ ] vim-plug is installed
- [ ] vimwiki is installed
- [ ] docker is installed
- [ ] earthly is installed

## Setup

### GitHub Publishing

To let GitHub Actions update your `gh-pages` branch whenever you push an update, add a secret to this repository called `ACCESS_TOKEN` containing a GitHub personal access token with `repo` access.

### Local Editing

If you want to edit the wiki locally, you should clone the repo and add the following to the end of your `.vimrc` or `init.vim`:

```vim
source ~/path/to/this/repo/init.vim
```

This will add the repo's wiki to your `g:vimwiki_list`.

## Building

```sh
earthly +build
```

