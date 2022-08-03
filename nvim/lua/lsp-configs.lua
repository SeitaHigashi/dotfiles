-- LSP Attach
local on_attach = function(client, bufnr)
  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end

  -- Enable completion triggered by <c-x><c-o>
  buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- Mappings.
  local opts = { noremap=true, silent=true }

  -- See `:help vim.lsp.*` for documentation on any of the below functions
  buf_set_keymap('n', 'gD', [[<cmd>lua vim.lsp.buf.declaration()<CR>]], opts)
  buf_set_keymap('n', 'gd', [[<cmd>lua require('telescope.builtin').lsp_definitions()<CR>]], opts)
  buf_set_keymap('n', 'gr', [[<cmd>lua require('telescope.builtin').lsp_references()<CR>]], opts)
  buf_set_keymap('n', 'gi', [[<cmd>lua require('telescope.builtin').lsp_implementations()<CR>]], opts)
  buf_set_keymap('n', 'K', [[<cmd>lua vim.lsp.buf.hover()<CR>]], opts)
  buf_set_keymap('n', '<C-k>', [[<cmd>lua vim.lsp.buf.signature_help()<CR>]], opts)
  buf_set_keymap('n', '<Leader>wa', [[<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>]], opts)
  buf_set_keymap('n', '<Leader>wr', [[<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>]], opts)
  buf_set_keymap('n', '<Leader>wl', [[<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>]], opts)
  buf_set_keymap('n', '<Leader>D', [[<cmd>lua vim.lsp.buf.type_definition()<CR>]], opts)
  buf_set_keymap('n', '<Leader>rn', [[<cmd>lua vim.lsp.buf.rename()<CR>]], opts)
  buf_set_keymap('n', '<Leader>ca', [[<cmd>lua vim.lsp.buf.code_action()<CR>]], opts)
  buf_set_keymap('n', '<Leader>e', [[<cmd>lua vim.diagnostic.open_float()<CR>]], opts)
  buf_set_keymap('n', '[d', [[<cmd>lua vim.diagnostic.goto_prev()<CR>]], opts)
  buf_set_keymap('n', ']d', [[<cmd>lua vim.diagnostic.goto_next()<CR>]], opts)
  buf_set_keymap('n', '<Leader>q', [[<cmd>lua vim.diagnostic.setloclist()<CR>]], opts)
  buf_set_keymap('n', '<Leader>=', [[<cmd>lua vim.lsp.buf.formatting()<CR>]], opts)

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
