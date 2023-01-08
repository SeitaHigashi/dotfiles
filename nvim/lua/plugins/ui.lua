return {
  -- StatusLine
  {
    'nvim-lualine/lualine.nvim',
    event = 'UIEnter',
    config = require('config.lualine'),
  },

  -- CommandLine
  {
    'folke/noice.nvim',
    config = require('config.noice'),
    event = 'UIEnter',
    dependencies = {
      { 'MunifTanjim/nui.nvim' },
      { 'rcarriga/nvim-notify' },
    },
  },

  {
    'rcarriga/nvim-notify',
    event = 'UIEnter',
    config = require('config.nvim-notify'),
  },

  {
    'gen740/SmoothCursor.nvim',
    event = 'UIEnter',
    config = require('config.smoothcursor'),
  },

  {
    'lukas-reineke/indent-blankline.nvim',
    event = 'UIEnter',
    config = require('config.indent-blankline'),
  },

  {
    'unblevable/quick-scope',
    event = 'UIEnter',
    init = function()
      vim.g.qs_highlight_on_keys = {'f', 'F'}
      local group = vim.api.nvim_create_augroup('qs_colors', { clear = true })
      vim.api.nvim_create_autocmd('ColorScheme', { pattern = '*', group = group, callback = function ()
        vim.api.nvim_set_hl(0, 'QuickScopePrimary', { fg = '#afff5f', underline = true, ctermfg = 155, cterm = { underline = true} })
        vim.api.nvim_set_hl(0, 'QuickScopeSecondary', { fg = '#5fffff', underline = true, ctermfg = 81, cterm = { underline = true} })
      end })
    end,
  },

  -- Improve the QuickFix
  {
    'kevinhwang91/nvim-bqf',
    ft = 'qf',
    config = require('config.nvim-bqf'),
  },

}
