-- default option
local d_opt = { noremap = true, silent = true }

-- Telescope
vim.keymap.set('n', '<Leader>j', require('telescope.builtin').find_files, d_opt)
vim.keymap.set('n', '<Leader>k', require('telescope.builtin').live_grep, d_opt)
vim.keymap.set('n', '<Leader>d', require('telescope.builtin').buffers, d_opt)
vim.keymap.set('n', '<Leader>h', require('telescope.builtin').keymaps, d_opt)
vim.keymap.set('n', '<Leader>f', require('telescope').extensions.file_browser.file_browser, d_opt)

-- Translate
vim.api.nvim_set_keymap('n', '<Leader>T', [[<cmd>TranslateW<CR>]], d_opt)

-- Terminal
vim.api.nvim_set_keymap('n', '<Leader>t', [[<cmd>Ttoggle 'resize=15'<CR>]], d_opt)
vim.api.nvim_set_keymap('t', '<ESC>', '<C-\\><C-n>', d_opt)
