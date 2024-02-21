M = {
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

-- If the system enables python3, rplugin will be enabled.
if vim.fn.has('python3') == 1 then
  M.performance.rtp.disabled_plugins = vim.tbl_filter(function(v)
    return v ~= 'rplugin'
  end, M.performance.rtp.disabled_plugins)
end

return M
