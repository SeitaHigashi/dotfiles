local wezterm = require 'wezterm'

local config = wezterm.config_builder()

config.window_background_opacity = 0.7
config.font = wezterm.font 'HackGen ConsoleNF'
config.font_size = 12.5
config.hide_tab_bar_if_only_one_tab = true

config.keys = {
  -- Switch to full screen with Alt(Opt)+Shift+F
  {
    key = 'f',
    mods = 'SHIFT|META',
    action = wezterm.action.ToggleFullScreen,
  },
}

return config
