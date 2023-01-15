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
  vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, bufopts)
  vim.keymap.set('n', 'gd',  require('telescope.builtin').lsp_definitions, bufopts)
  vim.keymap.set('n', '<Leader>pd', '<cmd>Lspsaga peek_definition<CR>', bufopts)
  vim.keymap.set('n', 'gr', require('telescope.builtin').lsp_references, bufopts)
  vim.keymap.set('n', 'gi', require('telescope.builtin').lsp_implementations, bufopts)
  vim.keymap.set('n', '<C-k>', vim.lsp.buf.signature_help, bufopts)
  vim.keymap.set('n', '<Leader>wa', vim.lsp.buf.add_workspace_folder, bufopts)
  vim.keymap.set('n', '<Leader>wr', vim.lsp.buf.remove_workspace_folder, bufopts)
  vim.keymap.set('n', '<Leader>wl', function() print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end, bufopts)
  vim.keymap.set('n', '<Leader>D', vim.lsp.buf.type_definition, bufopts)
  vim.keymap.set('n', '<Leader>rn', '<cmd>Lspsaga rename<CR>', bufopts)
  vim.keymap.set('n', '<Leader>ca', '<cmd>Lspsaga code_action<CR>', bufopts)
  vim.keymap.set('n', '<Leader>e', '<cmd>Lspsaga hover_doc<CR>', bufopts)
  vim.keymap.set('n', '[e', require('lspsaga.diagnostic').goto_prev, bufopts)
  vim.keymap.set('n', ']e', require('lspsaga.diagnostic').goto_next, bufopts)
  vim.keymap.set('n', '<Leader>q', vim.diagnostic.setloclist, bufopts)
  vim.keymap.set('n', '<Leader>=', vim.lsp.buf.format, bufopts)
  vim.keymap.set('n', '<Leader>l', '<cmd>Lspsaga lsp_finder<CR>', bufopts)
  vim.keymap.set('n', '<Leader>o', '<cmd>Lspsaga outline<CR>', bufopts)
  local installed_parsers = require('nvim-treesitter.info').installed_parsers()
  vim.keymap.set('n', 'K', vim.lsp.buf.hover, bufopts)
  for _, parser in pairs(installed_parsers) do
    if parser == "markdown" then
      vim.keymap.set('n', 'K', '<cmd>Lspsaga hover_doc<CR>', bufopts)
    end
  end
end

return M
