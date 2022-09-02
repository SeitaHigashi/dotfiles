-- LSP Attach
local on_attach = function(client, bufnr)

  -- Enable completion triggered by <c-x><c-o>
  vim.api.nvim_buf_set_option(bufnr, 'omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- Mappings.
  local bufopts = { noremap=true, silent=true, buffer=bufnr}

  -- See `:help vim.lsp.*` for documentation on any of the below functions
  vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, bufopts)
  vim.keymap.set('n', 'gd',  require('telescope.builtin').lsp_definitions, bufopts)
  vim.keymap.set('n', 'gr', require('telescope.builtin').lsp_references, bufopts)
  vim.keymap.set('n', 'gi', require('telescope.builtin').lsp_implementations, bufopts)
  vim.keymap.set('n', 'K', vim.lsp.buf.hover, bufopts)
  vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, bufopts)
  vim.keymap.set('n', '<Leader>wa', vim.lsp.buf.add_workspace_folder, bufopts)
  vim.keymap.set('n', '<space>wr', vim.lsp.buf.remove_workspace_folder, bufopts)
  vim.keymap.set('n', '<Leader>wl', function()
    print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
  end, bufopts)
  vim.keymap.set('n', '<Leader>D', vim.lsp.buf.type_definition, bufopts)
  vim.keymap.set('n', '<Leader>rn', vim.lsp.buf.rename, bufopts)
  vim.keymap.set('n', '<Leader>ca', require('lspsaga.codeaction').code_action, bufopts)
  vim.keymap.set('n', '<Leader>cd', require('lspsaga.diagnostic').show_cursor_diagnostics, bufopts)
  vim.keymap.set('n', '<Leader>e', vim.diagnostic.open_float, bufopts)
  vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, bufopts)
  vim.keymap.set('n', ']d', vim.diagnostic.goto_next, bufopts)
  vim.keymap.set('n', '<Leader>q', vim.diagnostic.setloclist, bufopts)
  vim.keymap.set('n', '<Leader>=', vim.lsp.buf.formatting, bufopts)

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
}
)

return {
  on_attach = on_attach
}
