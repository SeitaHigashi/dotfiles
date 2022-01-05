require('packer').startup(function()
  use {'wbthomason/packer.nvim'}

  -- Fuzzy Finder
  use {
    'nvim-telescope/telescope.nvim',
    requires = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-file-browser.nvim' },
      { 'nvim-telescope/telescope-packer.nvim' },
      { 'kyazdani42/nvim-web-devicons' },
    },
    config = function() require('config.telescope') end,
  }

  -- Complete
  use {
    'hrsh7th/nvim-cmp',
    requires = {
      { 'neovim/nvim-lspconfig' },
      { 'hrsh7th/cmp-nvim-lsp' },
      { 'hrsh7th/cmp-buffer' },
      { 'hrsh7th/cmp-path' },
      { 'hrsh7th/cmp-cmdline' },
      { 'onsails/lspkind-nvim' },
    },
    config = function() require('config.nvim-cmp') end,
  }

  use {
    'neovim/nvim-lspconfig',
    config = function() require('config.nvim-lspconfig') end,
  }

  use {
    'williamboman/nvim-lsp-installer',
    requires = {
      { 'neovim/nvim-lspconfig' },
    },
    config = function() require('config.nvim-lsp-installer') end,
  }

  --Snippets
  use {
    'hrsh7th/vim-vsnip',
  }

  use {
    'hrsh7th/vim-vsnip-integ',
    requires = {
      { 'hrsh7th/vim-vsnip' },
    },
  }

  --TagBar
  use {
    'liuchengxu/vista.vim',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = function() require('config.vista') end,
  }

  -- Treesitter
  use {
    'nvim-treesitter/nvim-treesitter',
    run = ':TSUpdate',
    config = function() require('config.treesitter') end,
  }

  -- Git
  use {
    'lewis6991/gitsigns.nvim',
    requires = { 'nvim-lua/plenary.nvim' },
    config = function() require('config.gitsigns') end,
  }
  --use('airblade/vim-gitgutter')

  use {'tpope/vim-fugitive', event = {'CmdlineEnter', 'CmdUndefined'}}

  --use('tpope/vim-rhubarb')


  -- StatusLine
  use {
    'nvim-lualine/lualine.nvim',
    requires = {
      { 'SeitaHigashi/lualine-hybrid.nvim' },
    },
    config = function() require('config.lualine') end,
  }

  -- ColorScheme
  use {'w0ng/vim-hybrid'}

  use {'tpope/vim-surround'}

  use {'jiangmiao/auto-pairs', event = 'InsertEnter'}

  use {
    'vim-scripts/vim-auto-save',
    event = 'InsertEnter',
    config = function()
      vim.g.auto_save = 1
      vim.g.auto_save_in_insert_mode = 0
    end,
  }

  use {
    'voldikss/vim-translator',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = function()
      vim.g.translator_target_lang = 'ja'
      vim.g.translator_default_engines = {'google'}
    end,
  }

  use {
    'unblevable/quick-scope',
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
  }

  use {
    'kassio/neoterm',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = function()
      vim.g.neoterm_autoinsert = 0
      vim.g.neoterm_autojump = 1
      vim.g.neoterm_autoscroll = 1
      vim.g.neoterm_default_mod = "botright"
    end
  }

  use {
    'dstein64/vim-startuptime',
    event = {'CmdlineEnter', 'CmdUndefined'},
  }

end)

