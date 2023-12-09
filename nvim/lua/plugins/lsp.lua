return {
  -- LSP settings
  {
    'williamboman/mason-lspconfig.nvim',
    dependencies = {
      { 'neovim/nvim-lspconfig' },
      { 'williamboman/mason.nvim', config = {} },
    },
    --lazy = false,
    event = 'VeryLazy',
    config = require('config.mason-lspconfig'),
  },

  -- improve the LSP related UI.
  {
    'nvimdev/lspsaga.nvim',
    cmd = "Lspsaga",
    event = "LspAttach",
    branch = 'main',
    dependencies = {
      {'nvim-tree/nvim-web-devicons'},
      {'nvim-treesitter/nvim-treesitter'},
    },
    opts = require('config.lspsaga'),
  },

  {
    'ray-x/lsp_signature.nvim',
    event = 'InsertEnter',
  },

}
