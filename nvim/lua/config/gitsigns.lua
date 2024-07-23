return function()
  require('gitsigns').setup {
    signs               = {
      add          = { text = '│'},
      change       = { text = '│'},
      delete       = { text = '_'},
      topdelete    = { text = '‾'},
      changedelete = { text = '~'},
      untracked    = { text = '┆'},
    },
    signcolumn          = true, -- Toggle with `:Gitsigns toggle_signs`
    numhl               = true, -- Toggle with `:Gitsigns toggle_numhl`
    linehl              = false, -- Toggle with `:Gitsigns toggle_linehl`
    word_diff           = false, -- Toggle with `:Gitsigns toggle_word_diff`
    watch_gitdir        = {
      interval = 1000,
      follow_files = true
    },
    attach_to_untracked = true,
    current_line_blame  = false, -- Toggle with `:Gitsigns toggle_current_line_blame`
    sign_priority       = 6,
    update_debounce     = 400,
    on_attach = function (bufnr)
      require('config.which-key').gitsigns(bufnr)
    end
  }
end
