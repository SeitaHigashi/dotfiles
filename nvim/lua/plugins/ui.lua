return {
  -- WhichKey
  {
    'folke/which-key.nvim',
    event = 'VeryLazy',
    init = function ()
      vim.o.timeout = true
      vim.o.timeoutlen = 300
    end,
    opts = require('config.which-key').setup,
  },

  -- StatusLine
  {
    'nvim-lualine/lualine.nvim',
    event = 'UIEnter',
    config = require('config.lualine'),
  },

  -- CommandLine
  {
    'folke/noice.nvim',
    -- enabled = false,
    config = require('config.noice'),
    event = 'UIEnter',
    dependencies = {
      { 'MunifTanjim/nui.nvim' },
      { 'rcarriga/nvim-notify' },
    },
  },

  {
    'rcarriga/nvim-notify',
    -- enabled = false,
    event = 'UIEnter',
    config = require('config.nvim-notify'),
  },

  {
    'gen740/SmoothCursor.nvim',
    dependencies = {
      'nvim-lualine/lualine.nvim',
    },
    event = 'VeryLazy',
    opts = function()
      local autocmd = vim.api.nvim_create_autocmd

      autocmd({ 'ModeChanged' }, {
        callback = function()
          local theme = require('lualine.themes.nordfox')
          local current_mode = vim.fn.mode()
          if current_mode == 'n' then
            vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.normal.a.bg })
            vim.fn.sign_define('smoothcursor', { text = '' })
          elseif current_mode == 'v' then
            vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.visual.a.bg })
            vim.fn.sign_define('smoothcursor', { text = '' })
          elseif current_mode == 'V' then
            vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.visual.a.bg })
            vim.fn.sign_define('smoothcursor', { text = '' })
          elseif current_mode == '' then
            vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.insert.a.bg })
            vim.fn.sign_define('smoothcursor', { text = '' })
          elseif current_mode == 'i' then
            vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.insert.a.bg })
            vim.fn.sign_define('smoothcursor', { text = '' })
          end
        end,
      })
      return { disable_float_win = true }
    end
  },

  {
    'lukas-reineke/indent-blankline.nvim',
    event = 'VeryLazy',
    config = require('config.indent-blankline'),
  },

  {
    'unblevable/quick-scope',
    event = 'VeryLazy',
    init = function()
      vim.g.qs_highlight_on_keys = { 'f', 'F' }
      local group = vim.api.nvim_create_augroup('qs_colors', { clear = true })
      vim.api.nvim_create_autocmd('ColorScheme', {
        pattern = '*',
        group = group,
        callback = function()
          vim.api.nvim_set_hl(0, 'QuickScopePrimary',
            { fg = '#afff5f', underline = true, ctermfg = 155, cterm = { underline = true } })
          vim.api.nvim_set_hl(0, 'QuickScopeSecondary',
            { fg = '#5fffff', underline = true, ctermfg = 81, cterm = { underline = true } })
        end
      })
    end,
  },

  -- Improve the QuickFix
  {
    'kevinhwang91/nvim-bqf',
    ft = 'qf',
    config = require('config.nvim-bqf'),
  },

  -- Improve the search highlight
  {
    'asiryk/auto-hlsearch.nvim',
    event = 'VeryLazy',
    opts = {},
  },

  -- Fun
  {
    'Eandrju/cellular-automaton.nvim',
    event = 'VeryLazy',
  },

  {
    'xiyaowong/transparent.nvim',
    lazy = false,
  }
}
