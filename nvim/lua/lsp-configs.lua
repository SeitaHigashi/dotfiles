local M = {}

-- LSP Attach
-- vim.lsp.config('*', {
--   on_attach = function (client, bufnr)
--     require('config.which-key').lsp(bufnr)
--     vim.lsp.inlay_hint.enable(true, {bufnr = bufnr})
--   end
-- })
vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local bufnr = args.buf
    local client = vim.lsp.get_client_by_id(args.data.client_id)

    -- Which-KeyのLSP用マップを登録
    require('config.which-key').lsp(bufnr)

    -- Inlay Hintの有効化（サーバーがサポートしている場合のみ有効化するのが安全です）
    if client and client.supports_method('textDocument/inlayHint') then
      vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
    end
  end,
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
