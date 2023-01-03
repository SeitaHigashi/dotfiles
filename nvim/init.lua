vim.g.mapleader = ' '

require('bootstrap')

local plugins = require('plugins')
local lazy_opts = {
  ui = {
    border = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
  }
}

require('lazy').setup(plugins, lazy_opts)

require('lsp-configs')
require('keybinds')

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

vim.cmd('colorscheme hybrid')

vim.cmd 'au BufNewFile,BufRead *.dart setf dart'

vim.api.nvim_set_hl(0, 'NormalFloat', { sp = Normal})
