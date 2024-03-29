-- Completeion plugin: nvim-cmp
return {
  {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      { 'onsails/lspkind-nvim' },
      { 'windwp/nvim-autopairs' },
    },
    config = require('config.nvim-cmp'),
  },

  -- Snippets
  {
    'L3MON4D3/LuaSnip',
    version = "v2.*",
    build = "make install_jsregexp",
    dependencies = {
      { 'saadparwaiz1/cmp_luasnip' },
      { 'rafamadriz/friendly-snippets' },
    }
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

  -- path
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
    event = 'LspAttach',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
    config = function()
      require('cmp_nvim_lsp').default_capabilities(vim.lsp.protocol.make_client_capabilities())
    end
  },

  -- CMP FileType
  {
    'hrsh7th/cmp-nvim-lua',
    ft = 'lua',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  -- others
  {
    --'lukas-reineke/cmp-rg',
    'SeitaHigashi/cmp-rg',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  -- serching in buffer
  {
    'hrsh7th/cmp-buffer',
    event = 'InsertEnter',
    dependencies = {
      { 'hrsh7th/nvim-cmp' },
    },
  },

  -- calcultor
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
}
