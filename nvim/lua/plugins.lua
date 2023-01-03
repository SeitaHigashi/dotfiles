return {
  {
    'https://github.com/folke/lazy.nvim',
    lazy = true,
    tag = 'stable',
  },
  -- Fuzzy Finder
  {
    'nvim-telescope/telescope.nvim',
    keys = '<Leader>',
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-file-browser.nvim' },
      { 'nvim-telescope/telescope-ui-select.nvim' },
      { 'xiyaowong/telescope-emoji.nvim' },
    },
    config = require('config.telescope'),
  },

  --LSP
  {
    'folke/trouble.nvim',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = require('config.trouble'),
  },

  -- Complete
  {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/cmp-nvim-lsp' },
      { 'onsails/lspkind-nvim' },
      { 'hrsh7th/cmp-buffer' },
      { 'hrsh7th/cmp-path' },
      { 'ray-x/cmp-treesitter', enabled = false },
      { 'saadparwaiz1/cmp_luasnip' },
    },
    config = require('config.nvim-cmp'),
  },

  {
    'williamboman/mason-lspconfig.nvim',
    dependencies = {
      { 'neovim/nvim-lspconfig' },
      { 'williamboman/mason.nvim', config = {} },
    },
    event = { 'BufEnter' },
    config = require('config.mason-lspconfig'),
  },

  {
    'ray-x/lsp_signature.nvim',
    event = "InsertEnter",
    lazy = true,
  },

  {
    "glepnir/lspsaga.nvim",
    branch = "main",
    lazy = true,
    config = require('config.lspsaga'),
  },

  {
    'jose-elias-alvarez/null-ls.nvim',
    enabled = false,
    event = 'BufEnter',
    config = require('config.null-ls'),
  },

  --CMD Line
  {
    'hrsh7th/cmp-cmdline',
    event = "CmdlineEnter",
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  -- LSP FileType
  {
    'hrsh7th/cmp-nvim-lua',
    ft = 'lua',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  --Snippets
  {
    'L3MON4D3/LuaSnip',
    lazy = true,
    dependencies = {
      { 'rafamadriz/friendly-snippets' },
    }
  },

  -- Treesitter
  {
    'nvim-treesitter/nvim-treesitter',
    enabled = false,
    build = ':TSUpdate',
    event = { 'BufEnter' },
    config = require('config.treesitter'),
  },

  -- Git
  {
    'lewis6991/gitsigns.nvim',
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
    },
    event = { 'BufEnter' },
    config = require('config.gitsigns'),
  },

  {
    'tpope/vim-fugitive',
    event = {'CmdlineEnter', 'CmdUndefined'}
  },

  -- StatusLine
  {
    'nvim-lualine/lualine.nvim',
    event = { 'UIEnter' },
    dependencies = {
      { 'SeitaHigashi/lualine-hybrid.nvim' },
    },
    config = require('config.lualine'),
  },

  {
    'folke/noice.nvim',
    config = require('config.noice'),
    event = { 'UIEnter' },
    dependencies = {
      { 'MunifTanjim/nui.nvim' },
      { 'rcarriga/nvim-notify' },
    },
  },

  {
    'rcarriga/nvim-notify',
    event = { 'UIEnter' },
    config = require('config.nvim-notify'),
  },

  -- ColorScheme
  {'w0ng/vim-hybrid'},

  {
    'tpope/vim-surround',
    event = { 'BufEnter' },
  },

  {
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    config = {},
  },

  {
    'vim-scripts/vim-auto-save',
    event = 'BufEnter',
    config = function()
      vim.g.auto_save = 1
      vim.g.auto_save_in_insert_mode = 0
      vim.g.auto_save_silent = 1
    end,
  },

  {
    'kyazdani42/nvim-web-devicons',
    lazy = true,
  },

  {
    'voldikss/vim-translator',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = function()
      vim.g.translator_target_lang = 'ja'
      vim.g.translator_default_engines = {'google'}
    end,
  },

  {
    'gen740/SmoothCursor.nvim',
    event = { 'UIEnter' },
    config = {},
  },

  {
    'unblevable/quick-scope',
    event = { 'UIEnter' },
    init = function()
      vim.g.qs_highlight_on_keys = {'f', 'F'}
      local group = vim.api.nvim_create_augroup('qs_colors', { clear = true })
      vim.api.nvim_create_autocmd('ColorScheme', { pattern = '*', group = group, callback = function ()
        vim.api.nvim_set_hl(0, 'QuickScopePrimary', { fg = '#afff5f', underline = true, ctermfg = 155, cterm = { underline = true} })
        vim.api.nvim_set_hl(0, 'QuickScopeSecondary', { fg = '#5fffff', underline = true, ctermfg = 81, cterm = { underline = true} })
      end })
    end,
  },

  {
    'kassio/neoterm',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = function()
      vim.g.neoterm_autoinsert = 0
      vim.g.neoterm_autojump = 1
      vim.g.neoterm_autoscroll = 1
      vim.g.neoterm_default_mod = "botright"
    end
  },

  {
    'dstein64/vim-startuptime',
    cmd = 'StartupTime',
  },

}

