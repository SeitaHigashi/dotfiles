vim.api.nvim_set_keymap('n', '<Leader>j', [[<Cmd>lua require('telescope.builtin').find_files()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>k', [[<Cmd>lua require('telescope.builtin').live_grep()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>d', [[<Cmd>lua require('telescope.builtin').buffers()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>f', [[<Cmd>lua require('telescope').extensions.file_browser.file_browser()<CR>]], { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<Leader>a', [[<Cmd>lua require('telescope').extensions.coc.code_actions()<CR>]], { noremap = true, silent = true })

local telescope = require('telescope')
local actions = require('telescope.actions')
local fb_actions = telescope.extensions.file_browser.actions

-- Telescope Setup
telescope.setup{
  defaults = {
    layout_strategy = 'vertical',
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
  },
  extensions = {
    file_browser = {
      mappings = {
        ["i"] = {
        },
      },
    },
  },
}

-- Load telescope extension
telescope.load_extension('coc')
telescope.load_extension('file_browser')

