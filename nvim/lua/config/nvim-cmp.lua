return function()
  local cmp = require('cmp')
  local luasnip = require('luasnip')
  local lspkind = require('lspkind')

  lspkind.init {
    mode = 'symbom_text',
  }

  local has_words_before = function()
    local cursor_table = vim.api.nvim_win_get_cursor(0)
    local line = cursor_table[1]
    local col = cursor_table[2]
    return col ~= 0 and vim.api.nvim_buf_get_lines(0, line - 1, line, true)[1]:sub(col, col):match("%s") == nil
  end

  local formatting_func = function(entry, vim_item)
    vim_item.kind = string.format("%s %s", lspkind.presets.default[vim_item.kind], vim_item.kind)
    vim_item.menu = ({
          nvim_lsp = " LSP",
          copilot = " Copilot",
          nvim_lua = " Lua",
          luasnip = " Snip",
          path = " Path",
          buffer = "﬘ Buffer",
          treesitter = " TS",
          calc = " Calc",
          rg = " RG",
          emoji = "ﲃ Emoji",
          nerdfont = "ﯔ Nerdfont",
        })[entry.source.name]

    return vim_item
  end

  local keymaps = {
    ['<C-b>'] = cmp.mapping(cmp.mapping.scroll_docs( -4), { 'i', 'c' }),
    ['<C-f>'] = cmp.mapping(cmp.mapping.scroll_docs(4), { 'i', 'c' }),
    ['<C-Space>'] = cmp.mapping(cmp.mapping.complete(), { 'i', 'c' }),
    ['<C-y>'] = cmp.config.disable, -- Specify `cmp.config.disable` if you want to remove the default `<C-y>` mapping.
    ['<C-e>'] = cmp.mapping({
      i = cmp.mapping.abort(),
      c = cmp.mapping.close(),
    }),
    ['<CR>'] = cmp.mapping.confirm({behavior = cmp.ConfirmBehavior.Replace, select = false }), -- Accept currently selected item. Set `select` to `false` to only confirm explicitly selected items.
    ["<Tab>"] = cmp.mapping(function(fallback)
      local entry = cmp.get_selected_entry()
      if cmp.visible() and entry  then
          cmp.confirm({behavior = cmp.ConfirmBehavior.Replace, select = false })
      elseif luasnip.expand_or_jumpable() then
        luasnip.expand_or_jump()
      elseif has_words_before() then
        cmp.complete()
      else
        fallback()
      end
    end, { "i", "s" }),
    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if luasnip.jumpable( -1) then
        luasnip.jump( -1)
      elseif cmp.visible() then
        fallback()
      end
    end, { "i", "s" }),
  }

  cmp.setup({
    completion = {
      completeopt = "menu,menuone,noselect",
    },
    snippet = {
      -- REQUIRED - you must specify a snippet engine
      expand = function(args)
        require('luasnip').lsp_expand(args.body)
      end,
    },
    mapping = cmp.mapping.preset.insert(keymaps),
    sorting = {
    },
    sources = cmp.config.sources({
      { name = 'nvim_lsp' },
      { name = 'copilot', keyword_length = 0 },
      { name = 'nvim_lua' },
      { name = 'luasnip' },
      { name = 'calc' },
    }, {
      { name = 'path' },
      { name = 'buffer' },
      {
        name = 'rg',
        option = {
          additional_arguments = "--max-depth 4 --follow --threads 1",
          cwd = function()
            return vim.fn.expand("%:p:h:h")
          end
        },
      },
      { name = 'treesitter' },
      { name = 'nerdfont',  insert = true },
      { name = 'emoji',     insert = true },
    }),
    formatting = {
      format = formatting_func,
    },
    window = {
      completion = cmp.config.window.bordered(),
      documentation = cmp.config.window.bordered(),
    },
    experimental = {
      ghost_text = true,
    },
  })

  -- Use buffer source for `/` (if you enabled `native_menu`, this won't work anymore).
  cmp.setup.cmdline('/', {
    sources = {
      { name = 'buffer' }
    },
    mapping = cmp.mapping.preset.cmdline(keymaps),
    formatting = {
      format = formatting_func,
    },
  })

  -- Use cmdline & path source for ':' (if you enabled `native_menu`, this won't work anymore).
  cmp.setup.cmdline(':', {
    sources = cmp.config.sources({
      { name = 'path' }
    }, {
      { name = 'cmdline', ignore_cmds = {} },
      { name = 'nvim_lua' },
    }),
    mapping = cmp.mapping.preset.cmdline(keymaps),
    formatting = {
      format = formatting_func,
    },
  })


  -- Auto pairs
  local cmp_autopairs = require('nvim-autopairs.completion.cmp')
  cmp.event:on('confirm_done', cmp_autopairs.on_confirm_done({ map_char = { tex = '' } }))
end
