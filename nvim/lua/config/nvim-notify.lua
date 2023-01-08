return function ()
  vim.notify = require('notify')
  vim.notify.setup({
    render = "minimal",
    timeout = 1000,
    stages = "slide",
    top_down = false,
    max_height = 5,
    max_width = function ()
      return vim.fn.winwidth(0) * 0.7
    end
  })
end
