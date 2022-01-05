vim.g.mapleader = ' '

vim.cmd('packadd packer.nvim')
require('plugins')
require('lsp-configs')

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

vim.api.nvim_set_keymap('n', '<Leader>T', [[<cmd>TranslateW<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>t', [[<cmd>Ttoggle 'resize=15'<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('t', '<ESC>', '<C-\\><C-n>', { noremap = true, silent = true })
