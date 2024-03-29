local lsp_installer = require("nvim-lsp-installer")

lsp_installer.on_server_ready(function(server)
  local opts = {}
  opts.on_attach = require('lsp-configs').on_attach
  server:setup(opts)
  vim.cmd [[ do User LspAttachBuffers ]]
end)
