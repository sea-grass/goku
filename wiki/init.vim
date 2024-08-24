let s:path = expand('<sfile>:p:h')
let s:wiki = { 'path': s:path . '/wiki', 'path_html': s:path . '/build' }

if exists("g:vimwiki_list[0]")
  call add(g:vimwiki_list, s:wiki)
else
  let s:default_wiki = { 'path': '~/vimwiki', 'path_html': '~/vimwiki_html' }
  let g:vimwiki_list = [s:default_wiki, s:wiki]
endif
