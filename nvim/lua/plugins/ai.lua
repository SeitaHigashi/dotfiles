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
    enabled = function()
      local mem = vim.fn.system("free -m | awk 'NR==2{printf $7}'")
      return tonumber(mem) > 1024 and vim.env.HOME_ENV
    end,
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
    enabled = function()
      local mem = vim.fn.system("free -m | awk 'NR==2{printf $7}'")
      return tonumber(mem) > 2048 and vim.env.HOME_ENV
    end,
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
      language = "English"
    },
    build = function()
      vim.notify("Please update the remote plugins by running ':UpdateRemotePlugins', then restart Neovim.")
    end,
    event = "VeryLazy",
    keys = {
      { "<leader>cce", "<cmd>CopilotChatExplain<cr>", desc = "CopilotChat - Explain code" },
      { "<leader>cct", "<cmd>CopilotChatTests<cr>", desc = "CopilotChat - Generate tests" },
      {
        "<leader>ccT",
        "<cmd>CopilotChatVsplitToggle<cr>",
        desc = "CopilotChat - Toggle Vsplit", -- Toggle vertical split
      },
      {
        "<leader>ccv",
        ":CopilotChatVisual",
        mode = "x",
        desc = "CopilotChat - Open in vertical split",
      },
      {
        "<leader>ccx",
        ":CopilotChatInPlace<cr>",
        mode = "x",
        desc = "CopilotChat - Run in-place code",
      },
      {
        "<leader>ccf",
        "<cmd>CopilotChatFixDiagnostic<cr>", -- Get a fix for the diagnostic message under the cursor.
        desc = "CopilotChat - Fix diagnostic",
      },
      {
        "<leader>ccr",
        "<cmd>CopilotChatReset<cr>", -- Reset chat history and clear buffer.
        desc = "CopilotChat - Reset chat history and clear buffer",
      }
    },
  },
}
