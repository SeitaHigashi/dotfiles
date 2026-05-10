local M = {}

function M.general()
  vim.keymap.set('t', '<ESC>', '<C-\\><C-n>', { noremap = true, silent = true })
  vim.keymap.set('n', '<F5>', ':DapContinue<CR>', { silent = true })
  vim.keymap.set('n', '<F10>', ':DapStepOver<CR>', { silent = true })
  vim.keymap.set('n', '<F11>', ':DapStepInto<CR>', { silent = true })
  vim.keymap.set('n', '<F12>', ':DapStepOut<CR>', { silent = true })
  vim.cmd [[cnoremap <expr><silent> <Space> getcmdtype() .. getcmdline() ==# ':h' ? '<C-u>Telescope help_tags<CR>' : ' ']]
end

return M
