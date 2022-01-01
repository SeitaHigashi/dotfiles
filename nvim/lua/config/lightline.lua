vim.g.lightline = {
  colorscheme = 'hybrid',
  active = {
    left = {
      { 'mode', 'paste' },
      { 'gitbranch', 'readonly', 'filename', 'modified', 'coc' },
    },
    right = {
      { 'lineinfo' },
      { 'percent' },
      { 'fileformat', 'fileencoding', 'filetype', 'charvaluehex' },
    },
  },
  inactive = {
    left = {
      { 'gitbranch', 'filename', 'coc' }
    },
    right = {
      {'lineinfo'},
      { 'percent' },
      { 'fileformat', 'fileencoding', 'filetype'},
    }
  },
  component_function = {
    gitbranch = 'FugitiveHead',
    coc = 'coc#status',
  },
  separator = {
    left = '',
    right = ''
  },
  subseparator = {
    left = '',
    right = '',
  },
}
