vim.api.nvim_set_keymap('n', '<Leader>j', [[<Cmd>lua require('telescope.builtin').find_files()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>k', [[<Cmd>lua require('telescope.builtin').live_grep()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>d', [[<Cmd>lua require('telescope.builtin').buffers()<CR>]], { noremap = true, silent = true })

local telescope = require('telescope')
local actions = require('telescope.actions')
telescope.setup{
  defaults = {
    mappings = {
      i = {
        ["J"] = actions.move_selection_next,
        ["K"] = actions.move_selection_previous,
        ["L"] = actions.select_default,
        ["Q"] = actions.close,
        ["<esc>"] = actions.close,
        ["V"] = actions.file_vsplit,
        ["S"] = actions.file_split,
      },
      n = {
        ["q"] = actions.close,
        ["Q"] = actions.close,
      }
    }
  },
  pickers = {
    find_files = {
      theme = "dropdown"
    }
  },
  extensions = {
  },
}

telescope.load_extension('coc')
