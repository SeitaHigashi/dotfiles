return {
  -- LSP settings
  {
    'williamboman/mason-lspconfig.nvim',
    dependencies = {
      { 'neovim/nvim-lspconfig' },
      { 'williamboman/mason.nvim', config = {} },
    },
    lazy = false,
    config = require('config.mason-lspconfig'),
  },

  -- Even if you are using a non-lsp tool, this tool can make it look like lsp.
  {
    'jose-elias-alvarez/null-ls.nvim',
    event = 'BufEnter',
    config = require('config.null-ls'),
  },

  {
    'jay-babu/mason-null-ls.nvim',
    event = 'BufEnter',
    dependencies = {
      'jose-elias-alvarez/null-ls.nvim',
    },
    opts = { automatic_setup = true },
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
