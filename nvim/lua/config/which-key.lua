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

      -- dap
      b = { "<cmd>DapToggleBreakpoint<CR>", "Toggle Breakpoint" }
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

M.lsp = function (bufnr)
  local wk = require('which-key')
  -- Goto
  wk.register({
    g = {
      D = { function () vim.lsp.buf.declaration() end, "Goto declaration" },
      d = { function () require('telescope.builtin').lsp_definitions() end, "Goto definition" },
      s = { function () require('telescope.builtin').lsp_dynamic_workspace_symbols() end, "Goto definition" },
      r = { function () require('telescope.builtin').lsp_references() end, "Goto references" },
      i = { function () require('telescope.builtin').lsp_implementations() end, "Goto implementations" },
    },
    ["<leader>"] = {
      ["pd"] = { '<cmd>Lspsaga peek_definition<CR>', "Peek definition"},
      w = {
        name = "LSP Workspace",
        a = { function () vim.lsp.buf.add_workspace_folder() end, "Add workspace folder" },
        r = { function () vim.lsp.buf.remove_workspace_folder() end, "Remove workspace folder" },
        l = { function () print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end, "List workspace folders" },
      },
      D = { function () vim.lsp.buf.type_definition() end, "Goto type definition" },
      ["rn"] = { '<cmd>Lspsaga rename<CR>', 'Rename'},
      ["ca"] = { '<cmd>Lspsaga code_action<CR>', 'Code actions'},
      e = { '<cmd>Lspsaga show_line_diagnostics<CR>', 'Show line diagnostics' },
      q = { function () vim.diagnostic.setloclist() end, "Set Location List" },
      l = { '<cmd>Lspsaga finder<CR>', "LSP Finder" },
      o = { '<cmd>Lspsaga outline<CR>', "LSP Outline" },
      ["="] = { function () vim.lsp.buf.format() end, "Code Format in buffer"},
      s = {
        name = "Show diagnostics",
        l = { function () require('lspsaga.diagnostic').show_line_diagnostics() end, "Show line diagnostics" },
        b = { function () require('lspsaga.diagnostic').show_buffer_diagnostics() end, "Show buffer diagnostics" },
        w = { function () require('lspsaga.diagnostic').show_cursor_diagnostics() end, "Show cursor diagnostics" },
      }
    },
    ["["] = {
      e = { function () require('lspsaga.diagnostic'):goto_prev() end, 'go to prev diagnostic'},
      E = { function () require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.ERROR }) end, 'go to prev error diagnostic'}
    },
    ["]"] = {
      e = { function () require('lspsaga.diagnostic'):goto_next() end, 'go to prev diagnostic'},
      E = { function () require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.ERROR }) end, 'go to prev error diagnostic'}
    }
  }, { buffer = bufnr, silent = true, noremap = true })
end

return M
