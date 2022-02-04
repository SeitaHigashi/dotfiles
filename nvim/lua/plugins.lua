require('packer').startup(function()
  use {'wbthomason/packer.nvim'}

  use {
    'nvim-lua/plenary.nvim',
    module = 'plenary',
  }

  -- Fuzzy Finder
  use {
    'nvim-telescope/telescope.nvim',
    keys = '<Leader>',
    requires = {
      { 'nvim-telescope/telescope-file-browser.nvim', module = 'telescope._extensions.file_browser' },
      { 'nvim-telescope/telescope-packer.nvim', module = 'telescope._extensions.packer' },
    },
    config = function() require('config.telescope') end,
  }

  --LSP
  use {
    'folke/trouble.nvim',
    event = {'CmdlineEnter', 'CmdUndefined'},
    config = function() require('config.trouble') end,
  }

  use {
    'j-hui/fidget.nvim',
    config = function() require('fidget').setup{} end,
  }

  -- Complete
  use {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    requires = {
      { 'hrsh7th/cmp-nvim-lsp', module = 'cmp_nvim_lsp' },
      { 'onsails/lspkind-nvim', module = 'lspkind' },
      { 'hrsh7th/cmp-nvim-lua', ft = 'lua' },
      { 'hrsh7th/cmp-buffer', after = 'nvim-cmp' },
      { 'hrsh7th/cmp-path', after = 'nvim-cmp' },
      { 'hrsh7th/cmp-cmdline', after = 'nvim-cmp' },
      { 'ray-x/cmp-treesitter', after = 'nvim-cmp' },
      { 'saadparwaiz1/cmp_luasnip', after = 'nvim-cmp' },
    },
    config = function() require('config.nvim-cmp') end,
  }

  use {
    'neovim/nvim-lspconfig',
    module = 'lspconfig',
  }

  use {
    'williamboman/nvim-lsp-installer',
    event = 'BufEnter',
    config = function() require('config.nvim-lsp-installer') end,
  }

  use {
    'ray-x/lsp_signature.nvim',
    event = "InsertEnter",
  }

  --Snippets
  use {
    'L3MON4D3/LuaSnip',
    module = 'luasnip',
  }

  use {
    'rafamadriz/friendly-snippets',
    after = 'LuaSnip',
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
    event = { 'BufEnter' },
    config = function() require('config.treesitter') end,
  }

  -- Git
  use {
    'lewis6991/gitsigns.nvim',
    event = { 'BufEnter' },
    config = function() require('config.gitsigns') end,
  }

  use {'tpope/vim-fugitive', event = {'CmdlineEnter', 'CmdUndefined'}}

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

  use {
    'tpope/vim-surround',
    event = { 'BufEnter' },
  }

  use {
    'windwp/nvim-autopairs',
    event = 'InsertEnter',
    module = 'nvim-autopairs',
    config = function() require('nvim-autopairs').setup {} end,
  }

  use {
    'vim-scripts/vim-auto-save',
    event = 'InsertEnter',
    config = function()
      vim.g.auto_save = 1
      vim.g.auto_save_in_insert_mode = 0
    end,
  }

  use { 'kyazdani42/nvim-web-devicons', module = 'nvim-web-devicons' }

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
    cmd = 'StartupTime',
  }

end)

