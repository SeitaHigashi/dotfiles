return function ()
  require("noice").setup({
    cmdline = {
      enabled = true, -- enables the Noice cmdline UI
      view = "cmdline_popup", -- view for rendering the cmdline. Change to `cmdline` to get a classic cmdline at the bottom
      opts = { buf_options = { filetype = "vim" } }, -- enable syntax highlighting in the cmdline
      format = {
        cmdline = { pattern = "^:", icon = "" },
        search_down = { kind = "search", pattern = "^/", icon = " ", ft = "regex" },
        search_up = { kind = "search", pattern = "^%?", icon = " ", ft = "regex" },
        filter = { pattern = "^:%s*!", icon = "$", ft = "sh" },
        lua = { pattern = "^:%s*lua%s+", icon = "", ft = "lua" },
      },
    },
    messages = {
      enabled = true, -- enables the Noice messages UI
      view = "notify", -- default view for messages
      view_error = "notify", -- view for errors
      view_warn = "notify", -- view for warnings
      view_history = "split", -- view for :messages
      view_search = "virtualtext", -- view for search count messages. Set to `false` to disable
    },
    popupmenu = {
      enabled = true, -- enables the Noice popupmenu UI
      backend = "cmp", -- backend to use to show regular cmdline completions
    },
    history = {
      view = "split",
      opts = { enter = true, format = "details" },
      filter = { event = { "msg_show", "notify" }, ["not"] = { kind = { "search_count", "echo" } } },
    },
    notify = {
      enabled = true,
      view = "notify",
    },
    lsp = {
      lsp_progress = {
        enabled = true,
        format = "lsp_progress",
        format_done = "lsp_progress_done",
        throttle = 1000 / 30, -- frequency to update lsp progress message
        view = "mini",
      },
      signature = {
        enabled = false,
      },
    },
    presets = {
      bottom_search = false, -- use a classic bottom cmdline for search
      command_palette = true, -- position the cmdline and popupmenu together
      long_message_to_split = false, -- long messages will be sent to a split
      inc_rename = false, -- enables an input dialog for inc-rename.nvim
      lsp_doc_border = false, -- add a border to hover docs and signature help
    },
    throttle = 1000 / 30, -- how frequently does Noice need to check for ui updates? This has no effect when in blocking mode.
  })
end
