local utils = require('utils')

return {
  {
    'zbirenbaum/copilot.lua',
    cmd = 'Copilot',
    opts = {
      suggestion = { enabled = false },
      panel = {
        enabled = false,
        layout = {
          position = 'right',
          ratio = 0.3,
        }
      }
    }
  },

  {
    'AndreM222/copilot-lualine',
    event = 'UIEnter',
  },

  {
    'zbirenbaum/copilot-cmp',
    event = 'InsertEnter',
    opts = {},
    dependencies  = {
      'zbirenbaum/copilot.lua',
    }
  },

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
    "CopilotC-Nvim/CopilotChat.nvim",
    opts = {
      show_help = "yes",
      debug = false,
      disable_extra_info = 'no',
      insert_at_end = true, -- Move cursor to end of buffer when inserting text
      clear_chat_on_new_prompt = true, -- Clears chat on every new prompt
      language = "English",
      window = {
        layout = "float"
      }
    },
    keys = {
      { "<leader><leader>e", "<cmd>CopilotChatExplain<cr>", desc = "CopilotChat - Explain code" },
      { "<leader><leader>t", "<cmd>CopilotChatTests<cr>", desc = "CopilotChat - Generate tests" },
      {
        "<leader><leader><leader>",
        "<cmd>CopilotChatToggle<cr>",
        desc = "CopilotChat - Toggle",
      },
      {
        "<leader><leader>f",
        "<cmd>CopilotChatFixDiagnostic<cr>", -- Get a fix for the diagnostic message under the cursor.
        desc = "CopilotChat - Fix diagnostic",
      },
      {
        "<leader><leader>g",
        "<cmd>CopilotChatCommit<cr>",
        desc = "CopilotChat - Generate commit comment based on staged changes",
      },
      {
        "<leader><leader>p",
        function()
          local actions = require("CopilotChat.actions")
          require("CopilotChat.integrations.telescope").pick(actions.prompt_actions())
        end,
        desc = "CopilotChat - Prompt actions",
      },
      {
        "<leader><leader>r",
        "<cmd>CopilotChatReset<cr>",
        desc = "CopilotChat - Reset chat history and clear buffer",
      }
    },
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
      }
    }
  }
}
