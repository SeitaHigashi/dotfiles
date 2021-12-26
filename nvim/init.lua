vim.g.mapleader = "<Space>"

vim.cmd('packadd packer.nvim')
require('plugins')
--require('plugins_lazy')

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
