local M = {}

M.setup = function()
  local wk = require('which-key')
  wk.add({
    { "<leader>j", function() require('telescope.builtin').find_files() end, desc = "Find file" },
    { "<leader>a", function() require('telescope.builtin').builtin() end, desc = "Telescope" },
    { "<leader>k", function() require('telescope.builtin').live_grep() end, desc = "Live grep" },
    { "<leader>d", function() require('telescope.builtin').buffers() end, desc = "Buffers" },
    { "<leader>f", function() require('telescope').extensions.file_browser.file_browser() end, desc = "File Browser" },
    { "<leader>T", "<cmd>TranslateW<CR>", desc = "Translate Word to Japanese" },
    { "<leader>t", "<cmd>Lspsaga term_toggle<CR>", desc = "Toggle terminal window" },

    -- dap
    { "<leader>b", "<cmd>DapToggleBreakpoint<CR>", desc = "Toggle Breakpoint" }
  })
  return {}
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
  wk.add({
    { "gD", function () vim.lsp.buf.declaration() end, desc = "Goto declaration" },
    { "gd", function () require('telescope.builtin').lsp_definitions() end, desc = "Goto definition" },
    { "gs", function () require('telescope.builtin').lsp_dynamic_workspace_symbols() end, desc = "Goto definition" },
    { "gr", function () require('telescope.builtin').lsp_references() end, desc = "Goto references" },
    { "gi", function () require('telescope.builtin').lsp_implementations() end, desc = "Goto implementations" },
    { "<leader>pd", '<cmd>Lspsaga peek_definition<CR>', desc = "Peek definition"},
    -- LSP Workspace
    { "<leader>wa", function () vim.lsp.buf.add_workspace_folder() end, desc = "Add workspace folder" },
    { "<leader>wr", function () vim.lsp.buf.remove_workspace_folder() end, desc = "Remove workspace folder" },
    { "<leader>wl", function () print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end, desc ="List workspace folders" },
    { "<leader>D", function () vim.lsp.buf.type_definition() end, desc = "Goto type definition" },
    { "<leader>rn", '<cmd>Lspsaga rename<CR>', desc = 'Rename'},
    { "<leader>ca", '<cmd>Lspsaga code_action<CR>', desc = 'Code actions'},
    { "<leader>e", '<cmd>Lspsaga show_line_diagnostics<CR>', desc = 'Show line diagnostics' },
    { "<leader>q", function () vim.diagnostic.setloclist() end, desc = "Set Location List" },
    { "<leader>l", '<cmd>Lspsaga finder<CR>', desc = "LSP Finder" },
    { "<leader>o", '<cmd>Lspsaga outline<CR>', desc = "LSP Outline" },
    { "<leader>=", function () vim.lsp.buf.format() end, desc = "Code Format in buffer"},
    -- SHow diagnostics
    { "<leader>s", function () require('lspsaga.diagnostic').show_line_diagnostics() end, desc = "Show line diagnostics" },
    { "<leader>s", function () require('lspsaga.diagnostic').show_buffer_diagnostics() end, desc = "Show buffer diagnostics" },
    { "<leader>s", function () require('lspsaga.diagnostic').show_cursor_diagnostics() end, desc = "Show cursor diagnostics" },
    { "[e", function () require('lspsaga.diagnostic'):goto_prev() end, desc = 'go to prev diagnostic'},
    { "[E", function () require('lspsaga.diagnostic'):goto_prev({ severity = vim.diagnostic.severity.ERROR }) end, desc = 'go to prev error diagnostic'},
    { "]e", function () require('lspsaga.diagnostic'):goto_next() end, desc = 'go to prev diagnostic'},
    { "]E", function () require('lspsaga.diagnostic'):goto_next({ severity = vim.diagnostic.severity.ERROR }) end, desc = 'go to prev error diagnostic'},
  })
end

return M
