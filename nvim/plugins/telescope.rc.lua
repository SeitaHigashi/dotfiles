vim.api.nvim_set_keymap('n', '<Leader>j', [[<Cmd>lua require('telescope.builtin').find_files()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>k', [[<Cmd>lua require('telescope.builtin').live_grep()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>d', [[<Cmd>lua require('telescope.builtin').buffers()<CR>]], { noremap = true, silent = true })

local actions = require('telescope.actions')
require('telescope').setup{
  defaults = {
    mappings = {
      i = {
        ["J"] = actions.move_selection_next,
        ["K"] = actions.move_selection_previous,
        ["Q"] = actions.close,
        ["<esc>"] = actions.close,
        ["L"] = actions.file_edit,
        ["E"] = actions.file_vsplit,
        ["H"] = actions.file_split,
      },
      n = {
        ["q"] = actions.close,
        ["Q"] = actions.close,
      }
    }
  }
}
