require('packer').startup(function()
  use('wbthomason/packer.nvim')

  -- Fuzzy Finder
  use({
    'nvim-telescope/telescope.nvim',
    requires = {
      { 'nvim-lua/plenary.nvim' },
      { 'fannheyward/telescope-coc.nvim' },
    },
  })

  -- Complete
  use({
    'neoclide/coc.nvim',
    branch = 'release'
  })

  -- Git
  use('airblade/vim-gitgutter')

  use('tpope/vim-fugitive')

  use('tpope/vim-rhubarb')


  -- StatusLine
  use({
    'itchyny/lightline.vim',
    config = function() require('config.lightline') end
  })

  use('cocopon/lightline-hybrid.vim')

  -- ColorScheme
  use('w0ng/vim-hybrid')


  use('tpope/vim-surround')

  use('jiangmiao/auto-pairs')
  use({
    'vim-scripts/vim-auto-save',
    config = function()
      vim.g.auto_save = 1
      vim.g.auto_save_in_insert_mode = 0
    end
  })

  use({
    'voldikss/vim-translator',
    config = function()
      vim.g.translator_target_lang = 'ja'
      vim.g.translator_default_engines = {'google'}
    end
  })

  use({
    'unblevable/quick-scope',
    config = function()
      vim.g.qs_highlight_on_keys = {'f', 'F'}
      vim.cmd([[
      augroup qs_colors
      autocmd!
      autocmd ColorScheme * highlight QuickScopePrimary guifg='#afff5f' gui=underline ctermfg=155 cterm=underline
      autocmd ColorScheme * highlight QuickScopeSecondary guifg='#5fffff' gui=underline ctermfg=81 cterm=underline
      augroup END
      ]])
    end
  })
end)
