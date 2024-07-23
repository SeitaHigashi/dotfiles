local M = {}

-- LSP Attach
function M.on_attach(client, bufnr)
  -- Enable completion triggered by <c-x><c-o>
  vim.api.nvim_buf_set_option(bufnr, 'omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- If vim version is 0.10.0 or later, enalbe the inlay hints
  if vim.fn.has('nvim-0.10') == 1 then
    vim.lsp.inlay_hint.enable(true, {bufnr = bufnr})
  end

  require('keybinds')['lsp'](bufnr)
  require('config.which-key').lsp(bufnr)

  require('lsp_signature').on_attach()
end

-- Diagnostic
local signs = {
  Error = " ",
  Warn = " ",
  Hint = " ",
  Info = " "
}

for type, icon in pairs(signs) do
  local hl = "DiagnosticSign" .. type
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = hl })
end

vim.diagnostic.config({
  virtual_text = false,
  signs = true,
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
