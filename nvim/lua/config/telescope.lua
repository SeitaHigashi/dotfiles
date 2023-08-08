return function()
  local telescope = require('telescope')
  local actions = require('telescope.actions')
  local fb_actions = require('telescope._extensions.file_browser.actions')
  local transform_mod = require('telescope.actions.mt').transform_mod

  local custom_actions = transform_mod({
    readonly = function()
      vim.o.readonly = true
    end,
  })

  -- Telescope Setup
  telescope.setup {
    defaults = {
      layout_strategy = 'horizontal',
      layout_config = { prompt_position = 'top', width = 0.95, height = 0.95 },
      sorting_strategy = 'ascending',
      mappings = {
        i = {
          ["J"] = actions.move_selection_next,
          ["K"] = actions.move_selection_previous,
          ["L"] = actions.select_default,
          ["Q"] = actions.close,
          ["<esc>"] = actions.close,
          ["V"] = actions.file_vsplit,
          ["S"] = actions.file_split,
          ["P"] = actions.select_default + custom_actions.readonly,
        },
        n = {
          ["J"] = actions.move_selection_next,
          ["K"] = actions.move_selection_previous,
          ["l"] = actions.select_default,
          ["L"] = actions.select_default,
          ["q"] = actions.close,
          ["Q"] = actions.close,
          ["v"] = actions.file_vsplit,
          ["V"] = actions.file_vsplit,
          ["s"] = actions.file_split,
          ["S"] = actions.file_split,
          ["p"] = actions.select_default + custom_actions.readonly,
          ["P"] = actions.select_default + custom_actions.readonly,
        }
      }
    },
    pickers = {
      buffers = { initial_mode = "normal" },
      lsp_definitions = { initial_mode = "normal" },
      lsp_references = { initial_mode = "normal" },
      lsp_implementations = { initial_mode = "normal" },
      lsp_code_actions = { initial_mode = "normal" },
    },
    extensions = {
      file_browser = {
        mappings = {
          i = {
            ["H"] = fb_actions.goto_parent_dir,
            ["N"] = fb_actions.create,
            ["R"] = fb_actions.rename,
            ["D"] = fb_actions.remove,
            ["P"] = fb_actions.copy,
            ["~"] = fb_actions.goto_cwd,
            ["."] = fb_actions.toggle_hidden,
          },
        },
      },
      lazy = {
        mappings = {
          open_in_browser = "B",
          open_in_find_files = "L",
          open_in_live_grep = "G",
          open_plugins_picker = "P",
        },
      },
    },
  }

  -- Load telescope extension
  telescope.load_extension('file_browser')
  telescope.load_extension('lazy')
  telescope.load_extension('ui-select')
  telescope.load_extension("emoji")
end
