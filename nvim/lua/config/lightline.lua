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
  component_function = {
    gitbranch = 'FugitiveHead',
    coc = 'coc#status'
  },
}
