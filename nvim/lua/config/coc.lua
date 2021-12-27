vim.g.coc_global_extensions = {
  'coc-snippets',
  'coc-lists',
}

-- TAB complete
function _G.check_back_space()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    return (col == 0 or vim.api.nvim_get_current_line():sub(col, col):match('%s')) and true
end

vim.api.nvim_set_keymap('i', '<TAB>', [[pumvisible() ? coc#_select_confirm() : coc#expandableOrJumpable() ? "\<C-r>=coc#rpc#request('doKeymap', ['snippets-expand-jump',''])\<CR>" : v:lua.check_back_space() ? "\<TAB>" : coc#refresh()]], { expr = true, noremap = true })

vim.g.coc_snippet_next = '<tab>'

-- Remap keys for gotos
vim.api.nvim_set_keymap('n', 'gd', [[<Plug>(coc-definition)]], { silent = true })
vim.api.nvim_set_keymap('n', 'gy', [[<Plug>(coc-type-definition)]], { silent = true })
vim.api.nvim_set_keymap('n', 'gi', [[<Plug>(coc-implementation)]], { silent = true })
vim.api.nvim_set_keymap('n', 'gr', [[<Plug>(coc-references)]], { silent = true })
vim.api.nvim_set_keymap('n', '<C-f>', [[<Plug>(coc-references)]], { noremap = true, silent = true })

-- Map rename
vim.api.nvim_set_keymap('n', '<Leader>rn', [[<Plug>(coc-rename)]], {})

-- Show documentation
vim.api.nvim_set_keymap('n', 'K', [[<Cmd>lua show_documentation()<CR>]], { noremap = true, silent = true })

function _G.show_documentation()
  if vim.fn['coc#rpc#ready']() then
    vim.cmd([[call CocActionAsync('doHover')]])
  --else
    --vim.cmd("execute '!' . &keywordprg . " " . expand('<cword>')")
  end
end

--function! s:show_documentation()
--  if (coc#rpc#ready())
--    call CocActionAsync('doHover')
--  else
--    execute '!' . &keywordprg . " " . expand('<cword>')
--  endif
--endfunction

--" Highlight
vim.cmd([[autocmd CursorHold * silent call CocActionAsync('highlight')]])

