return {
  -- Fuzzy Finder
  {
    'nvim-telescope/telescope.nvim',
    keys = '<Leader>',
    cmd = 'Telescope',
    dependencies = {
      { 'nvim-lua/plenary.nvim' },
      { 'nvim-telescope/telescope-file-browser.nvim' },
      { 'nvim-telescope/telescope-ui-select.nvim' },
      { 'nvim-telescope/telescope-frecency.nvim' },
      { 'xiyaowong/telescope-emoji.nvim' },
      { 'tsakirist/telescope-lazy.nvim' },
    },
    config = require('config.telescope'),
  },
}
