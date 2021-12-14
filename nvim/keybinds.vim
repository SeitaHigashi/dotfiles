" Terminal mode
tnoremap <ESC> <C-\><C-n>

tnoremap fk <UP>
tnoremap fj <DOWN>

" Normal mode
nnoremap <silent> <Leader>T <cmd>TranslateW<CR>
nnoremap <silent> <Leader>t <cmd>Ttoggle 'resize=15'<CR>
"   Denite
nnoremap <silent><Leader>j :<C-u>Denite -start_filter file/rec<CR>
nnoremap <silent><Leader>k :<C-u>Denite grep<CR>
nnoremap <silent><Leader>d :<C-u>Denite buffer<CR>
"   Defx
nnoremap <silent><Leader>f :<C-u>Defx -listed -columns=mark:indent:git:icons:filename:type<CR>
