local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.automatically_reload_config = true
config.font_size = 12
config.use_ime = true
config.window_background_opacity = 0.65
config.font = wezterm.font 'HackGen Console NF'
-- タブが一つの時は非表示
config.hide_tab_bar_if_only_one_tab = true
-- 
config.keys = {
  -- Switch to full screen with Alt(Opt)+Shift+F
  {
    key = 'f',
    mods = 'SHIFT|META',
    action = wezterm.action.ToggleFullScreen,
  },
}

-- タブバーの表示
config.show_tabs_in_tab_bar = true

-- タブの追加ボタンを非表示
config.show_new_tab_button_in_tab_bar = false
-- タブの閉じるボタンを非表示
config.show_close_tab_button_in_tabs = false

-- タブ同士の境界線を非表示
config.colors = {
  tab_bar = {
    inactive_tab_edge = "none",
  },
}

return config
