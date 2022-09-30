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
    module_pattern = 'telescope',
    requires = {
      { 'nvim-telescope/telescope-file-browser.nvim', module = 'telescope._extensions.file_browser' },
      { 'nvim-telescope/telescope-packer.nvim', module = 'telescope._extensions.packer' },
      { 'nvim-telescope/telescope-ui-select.nvim', module = 'telescope._extensions.ui-select'},
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
    module = 'cmp',
    requires = {
      { 'hrsh7th/cmp-nvim-lsp', module = 'cmp_nvim_lsp' },
      { 'onsails/lspkind-nvim', module = 'lspkind' },
      { 'hrsh7th/cmp-buffer', after = 'nvim-cmp' },
      { 'hrsh7th/cmp-path', after = 'nvim-cmp' },
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
    'williamboman/mason.nvim',
    config = function() require('mason').setup() end,
  }

  use {
    'williamboman/mason-lspconfig.nvim',
    config = function() require('config.mason-lspconfig') end,
  }

  use {
    'ray-x/lsp_signature.nvim',
    event = "InsertEnter",
    module = 'lsp_signature',
  }

  use {
    "glepnir/lspsaga.nvim",
    module_pattern = 'lspsaga',
    branch = "main",
    config = function() require('config.lspsaga') end
  }

  --CMD Line
  use {
    'hrsh7th/cmp-cmdline',
    event = "CmdlineEnter",
    requires = {
      { 'hrsh7th/nvim-cmp' },
    },
  }

  -- LSP FileType
  use {
    'hrsh7th/cmp-nvim-lua',
    ft = 'lua',
    requires = {
      { 'hrsh7th/nvim-cmp' },
    },
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
    'gen740/SmoothCursor.nvim',
    config = function()
      require('smoothcursor').setup()
    end
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

