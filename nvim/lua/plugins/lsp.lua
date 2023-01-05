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
    enabled = false,
    event = 'BufEnter',
    config = require('config.null-ls'),
  },

  -- display the information from lsp.
  {
    'folke/trouble.nvim',
    cmd = { 'Trouble', 'TroubleToggle', 'TroubleClose', 'TroubleRefresh' },
    config = require('config.trouble'),
  },

  -- improve the LSP related UI.
  {
    'glepnir/lspsaga.nvim',
    branch = 'main',
    config = require('config.lspsaga'),
  },

  {
    'ray-x/lsp_signature.nvim',
    event = 'InsertEnter',
  },

}
