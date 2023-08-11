local M = {}

function M.general()
  vim.api.nvim_set_keymap('t', '<ESC>', '<C-\\><C-n>', { noremap = true, silent = true })
  vim.cmd [[cnoremap <expr><silent> <Space> getcmdtype() .. getcmdline() ==# ':h' ? '<C-u>Telescope help_tags<CR>' : ' ']]
end

function M.lsp(bufnr)
  local bufopts = { noremap = true, silent = true, buffer = bufnr }
  local installed_parsers = require('nvim-treesitter.info').installed_parsers()
  vim.keymap.set('n', 'K', vim.lsp.buf.hover, bufopts)
  for _, parser in pairs(installed_parsers) do
    if parser == "markdown" then
      vim.keymap.set('n', 'K', '<cmd>Lspsaga hover_doc<CR>', bufopts)
    end
  end
end

return M
