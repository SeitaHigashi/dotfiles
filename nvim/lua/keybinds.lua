local M = {}

function M.general()
  vim.api.nvim_set_keymap('n', '<Leader>T', [[<cmd>TranslateW<CR>]], { noremap = true, silent = true })
  vim.api.nvim_set_keymap('n', '<Leader>t', [[<cmd>Ttoggle 'resize=15'<CR>]], { noremap = true, silent = true })
  vim.api.nvim_set_keymap('t', '<ESC>', '<C-\\><C-n>', { noremap = true, silent = true })
end

function M.telescope()
  vim.keymap.set('n', '<Leader>j', require('telescope.builtin').find_files, { noremap = true, silent = true })
  vim.keymap.set('n', '<Leader>k', require('telescope.builtin').live_grep, { noremap = true, silent = true })
  vim.keymap.set('n', '<Leader>d', require('telescope.builtin').buffers, { noremap = true, silent = true })
  vim.keymap.set('n', '<Leader>h', require('telescope.builtin').keymaps, { noremap = true, silent = true })
  vim.keymap.set('n', '<Leader>f', require('telescope').extensions.file_browser.file_browser, { noremap = true, silent = true })
end

function M.lsp(bufnr)
  local bufopts = { noremap=true, silent=true, buffer=bufnr}
  -- See `:help vim.lsp.*` for documentation on any of the below functions
  vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, bufopts)
  vim.keymap.set('n', 'gd',  require('telescope.builtin').lsp_definitions, bufopts)
  vim.keymap.set('n', '<Leader>pd', function() require('lspsaga.definition'):preview_definition() end, bufopts)
  vim.keymap.set('n', 'gr', require('telescope.builtin').lsp_references, bufopts)
  vim.keymap.set('n', 'gi', require('telescope.builtin').lsp_implementations, bufopts)
  vim.keymap.set('n', 'K', function () require('lspsaga.hover'):render_hover_doc() end, bufopts)
  vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, bufopts)
  vim.keymap.set('n', '<Leader>wa', vim.lsp.buf.add_workspace_folder, bufopts)
  vim.keymap.set('n', '<space>wr', vim.lsp.buf.remove_workspace_folder, bufopts)
  vim.keymap.set('n', '<Leader>wl', function() print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end, bufopts)
  vim.keymap.set('n', '<Leader>D', vim.lsp.buf.type_definition, bufopts)
  vim.keymap.set('n', '<Leader>rn', function() require('lspsaga.rename'):lsp_rename() end, bufopts)
  vim.keymap.set('n', '<Leader>ca', function() require('lspsaga.codeaction'):code_action() end, bufopts)
  vim.keymap.set('n', '<Leader>e', require('lspsaga.diagnostic').show_cursor_diagnostics, bufopts)
  vim.keymap.set('n', '[d', require('lspsaga.diagnostic').goto_prev, bufopts)
  vim.keymap.set('n', ']d', require('lspsaga.diagnostic').goto_next, bufopts)
  vim.keymap.set('n', '<Leader>q', vim.diagnostic.setloclist, bufopts)
  vim.keymap.set('n', '<Leader>=', vim.lsp.buf.format, bufopts)
  vim.keymap.set('n', '<Leader>l', function() require('lspsaga.finder'):lsp_finder() end, bufopts)
end

return M