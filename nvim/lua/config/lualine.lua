return function()
  local readonly = function()
    if vim.o.readonly then
      return "RO"
    else
      return ""
    end
  end

  local function clock()
    if vim.fn.winwidth(0) > 70 then
      if os.time() % 2 == 0 then
        -- Convert to JST from UTC
        return ' ' .. os.date("%H:%M", os.time() + 9 * 60 * 60)
      else
        return ' ' .. os.date("%H %M", os.time() + 9 * 60 * 60)
      end
    end
    return ''
  end

  require 'lualine'.setup {
    options = {
      icons_enabled = true,
      theme = 'nordfox',
      component_separators = { left = '', right = '' },
      section_separators = { left = '', right = '' },
      disabled_filetypes = {},
      always_divide_middle = true,
      globalstatus = true,
    },
    sections = {
      lualine_a = { 'mode' },
      lualine_b = { readonly, 'branch' },
      lualine_c = { 'filename', 'diff' },
      lualine_x = {
        {
          'copilot',
          show_colors = true,
        },
        'diagnostics',
        'encoding',
        'fileformat',
        'filetype'
      },
      lualine_y = { 'progress' },
      lualine_z = { 'location', clock }
    },
    tabline = {},
    extensions = { 'fugitive', 'quickfix' }
  }
end
