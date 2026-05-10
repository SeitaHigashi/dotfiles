local M = {}

-- LSP Attach
vim.lsp.config('*', {
  on_attach = function (client, bufnr)
    require('config.which-key').lsp(bufnr)
    vim.lsp.inlay_hint.enable(true, {bufnr = bufnr})
    vim.api.nvim_set_option(bufnr, 'omnifunc', 'v:lua.vim.lsp.omnifunc', { buf = bufnr})
  end

})

-- Diagnostic
vim.diagnostic.config({
  virtual_text = false,
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = '',
      [vim.diagnostic.severity.WARN] = '',
      [vim.diagnostic.severity.HINT] = '',
      [vim.diagnostic.severity.INFO] = '',
    },
  },
  underline = true,
  update_in_insert = false,
  sererity_sort = false,
})

vim.o.updatetime = 250

vim.lsp.handlers["textDocument/hover"] = vim.lsp.with(
  vim.lsp.handlers.hover, {
  border = { "╭", "─", "╮", "│", "╯", "─", "╰", "│" },
})

return M
