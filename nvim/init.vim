set number
set title
set expandtab
set autoindent
set smartindent
set shiftwidth=2
set softtabstop=2
set tabstop=2

if &compatible
  set nocompatible               " Be iMproved
endif

set runtimepath+=~/.local/share/nvim/repos/github.com/Shougo/dein.vim
call dein#begin('~/.local/share/nvim')

" Plugins
call dein#load_toml('~/.config/nvim/toml/dein.toml', {'lazy': 0})
call dein#load_toml('~/.config/nvim/toml/dein_lazy.toml', {'lazy': 1})

" Add or remove your plugins here like this:
"call dein#add('Shougo/neosnippet.vim')
"call dein#add('Shougo/neosnippet-snippets')

call dein#end()

" Required:
filetype plugin indent on
syntax enable

