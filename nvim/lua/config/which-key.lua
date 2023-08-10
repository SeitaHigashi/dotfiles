local M = {}

M.setup = function()
  local wk = require('which-key')

  wk.register({
    ["<leader>"] = {
      j = { function() require('telescope.builtin').find_files() end, "Find file" },
      a = { function() require('telescope.builtin').builtin() end, "Telescope" },
      k = { function() require('telescope.builtin').live_grep() end, "Live grep" },
      d = { function() require('telescope.builtin').buffers() end, "Buffers" },
      f = { function() require('telescope').extensions.file_browser.file_browser() end, "File Browser" },
      T = { "<cmd>TranslateW<CR>", "Translate Word to Japanese" },
      t = { "<cmd>Lspsaga term_toggle<CR>", "Toggle terminal window" },
    },
  })

  return {
  }
end

M.gitsigns = function(bufnr)
  local wk = require('which-key')
  local gs = package.loaded.gitsigns

  wk.register({
    -- Actions
    ["<leader>h"] = {
      name = "GitSigns",
      s = { function() gs.stage_hunk() end, "Stage hunk" },
      r = { function() gs.reset_hunk() end, "Reset hunk" },
      S = { function() gs.stage_buffer() end, "Stage buffer" },
      R = { function() gs.reset_buffer() end, "Reset buffer" },
      p = { function() gs.preview_hunk() end, "Preview hunk" },
      b = { function() gs.blame_line { full = true } end, "Blame line" },
      d = { function() gs.diffthis() end, "Diff this" },
      D = { function() gs.diffthis('~') end, "Diff this (ignore whitespace)" },
    }
  }, { buffer = bufnr })

  wk.register({
    ["<leader>h"] = {
      s = { function() gs.stage_hunk { vim.fn.line('.'), vim.fn.line('v') } end, "Select hunk" },
      r = { function() gs.reset_hunk { vim.fn.line('.'), vim.fn.line('v') } end, "Reset hunk" }
    }
  }, { mode = "v", buffer = bufnr })

  -- Navigation
  wk.register({
    ["]c"] = {
      function()
        if vim.wo.diff then return ']c' end
        vim.schedule(function() gs.next_hunk() end)
        return '<Ignore>'
      end,
      "Next Hunk",
      expr = true
    },
    ["[c"] = {
      function()
        if vim.wo.diff then return '[c' end
        vim.schedule(function() gs.prev_hunk() end)
        return '<Ignore>'
      end,
      "Previous Hunk",
      expr = true
    },
  }, { buffer = bufnr })

  -- Text object
  wk.register({
    ["ih"] = { '<cmd><C-U>Gitsigns select_hunk<CR>', "Select hunk" }
  }, { mode = { "o", "x" }, buffer = bufnr })
end

return M
