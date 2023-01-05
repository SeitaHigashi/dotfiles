return {
  spec = 'plugins',
  defaults = {
    lazy = true,
  },
  ui = {
    size = { width = 0.85, height = 0.85 },
    border = { '╭', '─', '╮', '│', '╯', '─', '╰', '│' },
  },
  performance = {
    rtp = {
      disabled_plugins = {
        'gzip',
        'matchit',
        'matchparen',
        'netrwPlugin',
        'tarPlugin',
        'rplugin',
        'tohtml',
        'tutor',
        'zipPlugin',
      }
    }
  },
  checker = {
    enabled = true,
  }
}
