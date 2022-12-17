return function ()
  local readonly = function ()
    if vim.o.readonly then
      return "RO"
    else
      return ""
    end
  end

  require'lualine'.setup {
    options = {
      icons_enabled = true,
      theme = require('lualine-hybrid'),
      component_separators = { left = '', right = ''},
      section_separators = { left = '', right = ''},
      disabled_filetypes = {},
      always_divide_middle = true,
    },
    sections = {
      lualine_a = {'mode'},
      lualine_b = {readonly, 'branch'},
      lualine_c = {'filename', 'diff'},
      lualine_x = {'diagnostics', 'encoding', 'fileformat', 'filetype'},
      lualine_y = {'progress'},
      lualine_z = {'location'}
    },
    inactive_sections = {
      lualine_a = {},
      lualine_b = {'branch'},
      lualine_c = {'filename'},
      lualine_x = {'filetype'},
      lualine_y = {'location'},
      lualine_z = {}
    },
    tabline = {},
    extensions = {}
  }
end
