local utils = require('utils')

return {
  {
    'folke/lazy.nvim',
    version = false,
  },
  -- Treesitter
  {
    'nvim-treesitter/nvim-treesitter',
    enabled = not (vim.fn.has('win32') == 1 and vim.fn.has('win64') == 1),
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
    event = { 'CmdlineEnter', 'CmdUndefined' }
  },

  -- ColorScheme
  { 'EdenEast/nightfox.nvim' },

  -- Related operator
  {
    'kylechui/nvim-surround',
    event = 'BufEnter',
    opts = {},
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

  -- Auto save
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
      vim.g.translator_default_engines = { 'google' }
    end,
  },

  {
    'kassio/neoterm',
    event = { 'CmdlineEnter', 'CmdUndefined' },
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

  {
    'andweeb/presence.nvim',
    enabled = vim.env.HOBBY,
    lazy = false,
    opts = {},
  }
}
