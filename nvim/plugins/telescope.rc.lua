vim.api.nvim_set_keymap('n', '<Leader>j', [[<Cmd>lua require('telescope.builtin').find_files()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>k', [[<Cmd>lua require('telescope.builtin').live_grep()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>d', [[<Cmd>lua require('telescope.builtin').buffers()<CR>]], { noremap = true, silent = true })
