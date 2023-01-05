vim.g.mapleader = ' '

require('bootstrap')

local lazy_opts = require('lazy-options')

require('lazy').setup(lazy_opts)

require('lsp-configs')

if vim.version().minor >= 8 then
  vim.o.cmdheight = 0
end

vim.o.laststatus = 3
vim.o.title = true
vim.o.expandtab = true
vim.o.autoindent = true
vim.o.smartindent = true
vim.o.shiftwidth = 2
vim.o.softtabstop = 2
vim.o.tabstop = 2
vim.o.showmode = false
vim.o.background = 'dark'
vim.o.number = true
vim.o.relativenumber = true
vim.o.hidden = true
vim.o.confirm = true

if vim.fn.has('termguicolors') then
  vim.o.termguicolors = true
end


vim.cmd('colorscheme nordfox')

vim.cmd 'au BufNewFile,BufRead *.dart setf dart'

vim.api.nvim_set_hl(0, 'NormalFloat', { sp = Normal})

require('keybinds')["general"]()
