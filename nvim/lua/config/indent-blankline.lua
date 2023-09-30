return function()
  -- vim.opt.list = true
  -- vim.opt.listchars:append "eol:↴"
  -- vim.api.nvim_set_hl(0, 'IndentBlanklineContextChar', { fg = '#808080', ctermfg = 244 })

  require("ibl").setup {
    -- if show_end_of_line is true, inserted the eol sing to blank line.
    -- show_current_context = true,
    indent = {
       char = "▏",
    },
  }
end
