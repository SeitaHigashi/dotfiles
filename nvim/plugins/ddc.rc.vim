" Customize global settings
call ddc#custom#patch_global('sources', [
      \ 'vsnip',
      \ 'nvim-lsp', 
      \ 'around'
      \ ])
call ddc#custom#patch_global('sourceOptions', {
      \ '_': { 
        \ 'matchers': ['matcher_head'],
        \ 'sorters': ['sorter_rank'] 
      \ },
      \ 'nvim-lsp': {
        \   'mark': 'LS',
        \   'dup': v:true,
        \   'forceCompletionPattern': '\w+' 
      \ },
      \ 'around': {'mark': 'A'},
      \ 'vsnip': {'mark': 'S', 'dup': v:true },
    \ })

" Mappings
inoremap <silent><expr> <TAB>
      \ pumvisible() ? '<C-f>' : '<TAB>'
" <TAB>: completion.
"  inoremap <silent><expr> <TAB>
"  \ pumvisible() ? '<C-n>' :
"  \ (col('.') <= 1 <Bar><Bar> getline('.')[col('.') - 2] =~# '\s') ?
"  \ '<TAB>' : ddc#map#manual_complete()

" <S-TAB>: completion back.
inoremap <expr><S-TAB>  pumvisible() ? <C-p>' : '<C-h>'

" Use ddc.
call ddc#enable()

