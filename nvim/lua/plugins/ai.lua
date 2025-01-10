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
      language = "English",
      window = {
        layout = "float"
      }
    },
    event = "VeryLazy",
    keys = {
      { "<leader><leader>e", "<cmd>CopilotChatExplain<cr>", desc = "CopilotChat - Explain code" },
      { "<leader><leader>t", "<cmd>CopilotChatTests<cr>", desc = "CopilotChat - Generate tests" },
      {
        "<leader><leader><leader>",
        "<cmd>CopilotChatToggle<cr>",
        desc = "CopilotChat - Toggle",
      },
      {
        "<leader><leader>v",
        ":CopilotChatVisual",
        mode = "x",
        desc = "CopilotChat - Open in vertical split",
      },
      {
        "<leader><leader>x",
        ":CopilotChatInPlace<cr>",
        mode = "x",
        desc = "CopilotChat - Run in-place code",
      },
      {
        "<leader><leader>f",
        "<cmd>CopilotChatFixDiagnostic<cr>", -- Get a fix for the diagnostic message under the cursor.
        desc = "CopilotChat - Fix diagnostic",
      },
      {
        "<leader><leader>g",
        "<cmd>CopilotChatCommitStaged<cr>", -- Reset chat history and clear buffer.
        desc = "CopilotChat - Generate commit comment based on staged changes",
      },
      {
        "<leader><leader>r",
        "<cmd>CopilotChatReset<cr>", -- Reset chat history and clear buffer.
        desc = "CopilotChat - Reset chat history and clear buffer",
      }
    },
  },

  {
    'tzachar/cmp-ai',
    event = 'InsertEnter',
    dependencies = {
      'nvim-lua/plenary.nvim'
    },
    config = function()
      local cmp_ai = require('cmp_ai.config')
      cmp_ai:setup({
        provider = 'Ollama',
        provider_options = {
          model = 'codegemma:2b',
          base_url = 'http://ollama.seita.home:11434/api/generate',
        },
        notify = true,
        notify_callback = function(msg)
          vim.notify(msg)
        end,
        run_on_every_keystroke = false,
        ignored_file_types = {
          -- default is not to ignore
          -- uncomment to ignore in lua:
          -- lua = true
        },
      })
    end,
  },

  {
    'nomnivore/ollama.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
    },
    cmd = { "Ollama", "OllamaModel", "OllamaServe", "OllamaServeStop" },
    keys = {
    -- Sample keybind for prompt menu. Note that the <c-u> is important for selections to work properly.
      {
        "<leader>oo",
        ":<c-u>lua require('ollama').prompt()<cr>",
        desc = "ollama prompt",
        mode = { "n", "v" },
      },

      -- Sample keybind for direct prompting. Note that the <c-u> is important for selections to work properly.
      {
        "<leader>oG",
        ":<c-u>lua require('ollama').prompt('Generate_Code')<cr>",
        desc = "ollama Generate Code",
        mode = { "n", "v" },
      },
    },
    ---@type Ollama.Config
    opts = {
      model = "codegemma:2b",
      url = "http://ollama.seita.home:11434",
    }
  },
}
