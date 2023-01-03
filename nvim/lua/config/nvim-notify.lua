return function ()
  vim.notify = require('notify')
  vim.notify.setup({
    render = "minimal",
    timeout = 1000,
    stages = "slide",
    max_height = 5,
  })
end
