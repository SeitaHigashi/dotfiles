let mapleader = "\<Space>"

if &compatible
  set nocompatible               " Be iMproved
endif

let g:floating_win_width_percent = 0.95
let g:floating_win_height_percent = 0.75

set runtimepath+=~/.local/share/nvim/repos/github.com/Shougo/dein.vim
call dein#begin('~/.local/share/nvim')

" Plugins
call dein#load_toml('~/.config/nvim/toml/dein.toml', {'lazy': 0})
call dein#load_toml('~/.config/nvim/toml/dein_lazy.toml', {'lazy': 1})

call dein#end()

" If you want to install not installed plugins on startup.
if dein#check_install()
 call dein#install()
endif

" Required:
filetype plugin indent on
syntax enable

set title
set expandtab
set autoindent
set smartindent
set shiftwidth=2
set softtabstop=2
set tabstop=2
set noshowmode
set background=dark
set number relativenumber
set clipboard=unnamedplus
colorscheme hybrid

au BufNewFile,BufRead *.dart setf dart

source ~/.config/nvim/keybinds.vim
