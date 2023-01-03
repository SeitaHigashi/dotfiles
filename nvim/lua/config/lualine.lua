return function ()
  local readonly = function ()
    if vim.o.readonly then
      return "RO"
    else
      return ""
    end
  end

  local function clock()
    if vim.fn.winwidth(0) > 70 then
      if os.time() % 2 == 0 then
        return ' ' .. os.date("%H:%M")
      else
        return ' ' .. os.date("%H %M")
      end
    end
    return ''
  end

  require'lualine'.setup {
    options = {
      icons_enabled = true,
      theme = require('lualine-hybrid'),
      component_separators = { left = '', right = ''},
      section_separators = { left = '', right = ''},
      disabled_filetypes = {},
      always_divide_middle = true,
      globalstatus = true,
    },
    sections = {
      lualine_a = { 'mode' },
      lualine_b = { readonly, 'branch' },
      lualine_c = { 'filename', 'diff' },
      lualine_x = { 'diagnostics', 'encoding', 'fileformat', 'filetype' },
      lualine_y = { 'progress' },
      lualine_z = { 'location', clock }
    },
    --  if laststatus is 3, disabled inactive_sections.
    --inactive_sections = {
    --  lualine_a = {},
    --  lualine_b = {'branch'},
    --  lualine_c = {'filename'},
    --  lualine_x = {'filetype'},
    --  lualine_y = {'location'},
    --  lualine_z = { clock }
    --},
    tabline = {},
    extensions = {'fugitive', 'quickfix'}
  }
end
