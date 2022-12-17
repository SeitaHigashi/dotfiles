return function ()
  vim.notify = require('notify')
  vim.notify.setup({
    render = "minimal",
    timeout = 1500,
    stages = "slide",
    max_height = 5,
  })
end
