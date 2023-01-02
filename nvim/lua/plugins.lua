require('lazy').setup({

  -- Fuzzy Finder
  {
    'nvim-telescope/telescope.nvim',
    keys = '<Leader>',
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-file-browser.nvim' },
      --{ 'nvim-telescope/telescope-packer.nvim' },
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
    'neovim/nvim-lspconfig',
    lazy = true,
  },

  {
    'williamboman/mason.nvim',
    config = function() require('mason').setup() end,
  },

  {
    'williamboman/mason-lspconfig.nvim',
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
    --run = ':TSUpdate',
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

  {'tpope/vim-fugitive', event = {'CmdlineEnter', 'CmdUndefined'}},

  -- StatusLine
  {
    'nvim-lualine/lualine.nvim',
    dependencies = {
      { 'SeitaHigashi/lualine-hybrid.nvim' },
    },
    config = require('config.lualine'),
  },

  {
    'folke/noice.nvim',
    config = require('config.noice'),
    event = { 'VimEnter' },
    dependencies = {
      { 'MunifTanjim/nui.nvim' },
      { 'rcarriga/nvim-notify' },
    },
  },

  {
    'rcarriga/nvim-notify',
    event = { 'VimEnter' },
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
    config = function() require('nvim-autopairs').setup {} end,
  },

  {
    'vim-scripts/vim-auto-save',
    event = 'InsertEnter',
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
    config = function()
      require('smoothcursor').setup()
    end
  },

  {
    'unblevable/quick-scope',
    enabled = false,
    config = function()
      vim.g.qs_highlight_on_keys = {'f', 'F'}
      vim.cmd([[
      augroup qs_colors
      autocmd!
      autocmd ColorScheme * highlight QuickScopePrimary guifg='#afff5f' gui=underline ctermfg=155 cterm=underline
      autocmd ColorScheme * highlight QuickScopeSecondary guifg='#5fffff' gui=underline ctermfg=81 cterm=underline
      augroup END
      ]])
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

})

