local utils = require('utils')

return {
  {
    'jackMort/ChatGPT.nvim',
    -- If OPENAI_API_KEY is not set, this plugin will not load.
    enabled = function()
      return vim.env.OPENAI_API_KEY ~= nil
    end,
    event = 'VeryLazy',
    opts = {},
    dependencies = {
      'MunifTanjim/nui.nvim',
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope.nvim',
    },
  },

  -- Codeium
  -- If memory free space is lower than 1GB, disable this plugin.
  {
    "Exafunction/codeium.nvim",
    enabled = function() return utils.memory_available() > 1024 and vim.env.HOME_ENV end,
    event = 'VeryLazy',
    dependencies = {
        "nvim-lua/plenary.nvim",
        "hrsh7th/nvim-cmp",
    },
    config = function()
        require("codeium").setup({
        })
    end
  },

  -- Tabnine
  -- If memory free space is lower than 2GB, disable this plugin.
  {
    'tzachar/cmp-tabnine',
    enabled = function() return utils.memory_available() > 2048 and vim.env.HOME_ENV end,
    event = 'InsertEnter',
    build = "./install.sh",
    config = function()
      local tabnine = require('cmp_tabnine.config')
      tabnine:setup({
      max_lines = 1000;
      max_num_results = 20;
      sort = true;
      run_on_every_keystroke = true;
      snippet_placeholder = '..';
      show_prediction_strength = false;
      })
    end,
  },
  {
    'coder/claudecode.nvim',
    dependencies = { "folke/snacks.nvim", lazy = false, priority = 1000 , opts = {}},
    event = 'VeryLazy',
    opts = {
      terminal = {
        split_width_percentage = 0.40,
      },
      diff_opts = {
        keep_terminal_focus = true,
      },
    },
    keys = {
      { "<leader><leader><leader>", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude" },
    }
  },

  {
    "folke/sidekick.nvim",
    event = 'VeryLazy',
    opts = {
      cli = {
        mux = {
          backend = "zellij",
          enabled = true,
        }
      },
      -- keys = {
      --   {
      --     "<tab>",
      --     function()
      --       -- if there is a next edit, jump to it, otherwise apply it if any
      --       if not require("sidekick").nes_jump_or_apply() then
      --         return "<Tab>" -- fallback to normal tab
      --       end
      --     end,
      --     expr = true,
      --     desc = "Goto/Apply Next Edit Suggestion",
      --   },
      -- },
    }
  }
}
