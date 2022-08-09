local mason_lspconfig = require('mason-lspconfig')
local nvim_lsp = require('lspconfig')

mason_lspconfig.setup_handlers {
  function(server_name)
    local opts = {}
    opts.on_attach = require('lsp-configs').on_attach
    nvim_lsp[server_name].setup(opts)
    vim.cmd [[ do User LspAttachBuffers ]]
  end
}
