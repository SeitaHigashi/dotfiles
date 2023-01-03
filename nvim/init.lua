vim.g.mapleader = ' '

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require('plugins')
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

vim.cmd('colorscheme hybrid')

vim.cmd 'au BufNewFile,BufRead *.dart setf dart'

vim.api.nvim_set_hl(0, 'NormalFloat', { sp = Normal})

vim.api.nvim_set_keymap('n', '<Leader>T', [[<cmd>TranslateW<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>t', [[<cmd>Ttoggle 'resize=15'<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('t', '<ESC>', '<C-\\><C-n>', { noremap = true, silent = true })
