return function ()
  require('smoothcursor').setup()
  local utils = require('smoothcursor.utils')

  --vim.api.nvim_create_autocmd('BufEnter', { pattern = '*', group = group, callback = function ()
  vim.api.nvim_create_autocmd('BufEnter', { pattern = '*', callback = function ()
    utils.smoothcursor_start()
  end })

  vim.api.nvim_create_autocmd('BufLeave', { pattern = '*', callback = function ()
    utils.smoothcursor_stop()
  end })
end
