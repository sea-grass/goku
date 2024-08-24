set nocompatible
filetype plugin on
syntax on

call plug#begin(stdpath('data') . '/plugged')
Plug 'vimwiki/vimwiki'
call plug#end()

let g:vimwiki_list = [{'path': '~/wiki', 'path_html': '~/build'}]
