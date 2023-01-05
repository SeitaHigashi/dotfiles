local utils = require('utils')

return {
  {
    'https://github.com/folke/lazy.nvim',
    tag = 'stable',
  },
  -- Fuzzy Finder
  {
    'nvim-telescope/telescope.nvim',
    keys = '<Leader>',
    cmd = 'Telescope',
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-file-browser.nvim' },
      { 'nvim-telescope/telescope-ui-select.nvim' },
      { 'xiyaowong/telescope-emoji.nvim' },
      { 'tsakirist/telescope-lazy.nvim' },
    },
    config = require('config.telescope'),
  },

  --LSP
  {
    'folke/trouble.nvim',
    cmd = { 'Trouble', 'TroubleToggle', 'TroubleClose', 'TroubleRefresh' },
    config = require('config.trouble'),
  },

  -- Complete
  {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      { 'onsails/lspkind-nvim' },
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
    event = 'BufEnter',
    config = require('config.mason-lspconfig'),
  },

  {
    'ray-x/lsp_signature.nvim',
    event = 'InsertEnter',
  },

  {
    'glepnir/lspsaga.nvim',
    branch = 'main',
    config = require('config.lspsaga'),
  },

  {
    'jose-elias-alvarez/null-ls.nvim',
    enabled = false,
    event = 'BufEnter',
    config = require('config.null-ls'),
  },

  -- nvim-cmp sources
  -- cmdline
  {
    'hrsh7th/cmp-cmdline',
    event = 'CmdlineEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  {
    'hrsh7th/cmp-path',
    event = 'CmdlineEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  -- LSP
  {
    'hrsh7th/cmp-nvim-lsp',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
    config = function ()
      require('cmp_nvim_lsp').default_capabilities(vim.lsp.protocol.make_client_capabilities())
    end
  },

  -- LSP FileType
  {
    'hrsh7th/cmp-nvim-lua',
    ft = 'lua',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  -- others
  {
    'lukas-reineke/cmp-rg',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  {
    'hrsh7th/cmp-buffer',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  {
    'hrsh7th/cmp-calc',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  {
    'hrsh7th/cmp-emoji',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  {
    'chrisgrieser/cmp-nerdfont',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  {
    'ray-x/cmp-treesitter',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  --Snippets
  {
    'L3MON4D3/LuaSnip',
    dependencies = {
      { 'rafamadriz/friendly-snippets' },
    }
  },

  -- Treesitter
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate',
    event = 'UIEnter',
    tag = 'v0.8.1',
    config = require('config.treesitter'),
  },

  -- Git
  {
    'lewis6991/gitsigns.nvim',
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
    },
    event = 'UIEnter',
    config = require('config.gitsigns'),
  },

  {
    'tpope/vim-fugitive',
    event = {'CmdlineEnter', 'CmdUndefined'}
  },

  -- StatusLine
  {
    'nvim-lualine/lualine.nvim',
    event = 'UIEnter',
    config = require('config.lualine'),
  },

  {
    'folke/noice.nvim',
    config = require('config.noice'),
    event = 'UIEnter',
    dependencies = {
      { 'MunifTanjim/nui.nvim' },
      { 'rcarriga/nvim-notify' },
    },
  },

  {
    'rcarriga/nvim-notify',
    event = 'UIEnter',
    config = require('config.nvim-notify'),
  },

  {
    'kevinhwang91/nvim-bqf',
    ft = 'qf',
    config = require('config.nvim-bqf'),
  },

  -- ColorScheme

  { 'EdenEast/nightfox.nvim'},

  {
    'tpope/vim-surround',
    event = 'BufEnter',
  },

  {
    'tpope/vim-repeat',
    event = 'BufEnter',
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
  },

  {
    'voldikss/vim-translator',
    enabled = utils.system_check('python'),
    cmd = { 'Translate', 'TranslateH', 'TranslateL', 'TranslateR', 'TranslateW', 'TranslateX' },
    config = function()
      vim.g.translator_target_lang = 'ja'
      vim.g.translator_default_engines = {'google'}
    end,
  },

  {
    'gen740/SmoothCursor.nvim',
    event = 'UIEnter',
    config = {},
  },

  {
    'lukas-reineke/indent-blankline.nvim',
    event = 'UIEnter',
    config = require('config.indent-blankline'),
  },

  {
    'unblevable/quick-scope',
    event = 'UIEnter',
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
      vim.g.neoterm_default_mod = 'botright'
    end
  },

  {
    'dstein64/vim-startuptime',
    cmd = 'StartupTime',
  },

}

