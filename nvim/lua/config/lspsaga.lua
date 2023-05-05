return {
  preview = {
    lines_below = 15,
  },
  ui = {
    border = 'rounded',
    winblend = 0,
    colors = {
      normal_bg = require("nightfox.palette.nordfox").palette.bg1,
    }
  },
  outline = {
    win_width = 25,
  },
  code_action = {
    show_server_names = true,
    keys = {
      quit = {'<Esc>', 'q'},
      exec = {'<CR>', 'l', 'L'},
    },
  },
  lightbulb = {
    sign = false,
  },
}
