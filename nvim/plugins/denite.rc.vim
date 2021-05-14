" Denite config 
nnoremap <silent>fj :<C-u>Denite buffer file/rec<CR>

" Define mappings
autocmd FileType denite call s:denite_my_settings()
function! s:denite_my_settings() abort
  nnoremap <silent><buffer><expr> <CR>
        \ denite#do_map('do_action')
  nnoremap <silent><buffer><expr> l
        \ denite#do_map('do_action')
  nnoremap <silent><buffer><expr> d
        \ denite#do_map('do_action', 'delete')
  nnoremap <silent><buffer><expr> p
        \ denite#do_map('do_action', 'preview')
  nnoremap <silent><buffer><expr> q
        \ denite#do_map('quit')
  nnoremap <silent><buffer><expr> i
        \ denite#do_map('open_filter_buffer')
  nnoremap <silent><buffer><expr> <Space>
        \ denite#do_map('toggle_select').'j'
endfunction

autocmd FileType denite-filter call s:denite_filter_my_settings()
function! s:denite_filter_my_settings() abort
  imap <silent><buffer> <C-o> <Plug>(denite_filter_quit)
endfunction

" Floating
let s:denite_win_width_percent = 0.9
let s:denite_win_height_percent = 0.8

" Change denite default options
call denite#custom#option('default', {
\ 'auto_action': 'preview',
\ 'floating_preview': v:true,
\ 'preview_height': float2nr(&lines * s:denite_win_height_percent),
\ 'preview_width': float2nr(&columns * s:denite_win_width_percent / 2),
\ 'prompt': '% ',
\ 'split': 'floating',
\ 'vertical_preview': v:true,
\ 'wincol': float2nr((&columns - (&columns * s:denite_win_width_percent)) / 2),
\ 'winheight': float2nr(&lines * s:denite_win_height_percent),
\ 'winrow': float2nr((&lines - (&lines * s:denite_win_height_percent)) / 2),
\ 'winwidth': float2nr(&columns * s:denite_win_width_percent / 2),
\ })

" For ripgrep
call denite#custom#var('file/rec', 'command',
      \ ['rg', '--files', '--glob', '!.git', '--color', 'never'])

" Change matchers.
call denite#custom#source(
      \ 'file_mru', 'matchers', ['matcher/fuzzy', 'matcher/project_files'])
call denite#custom#source(
      \ 'file/rec', 'matchers', ['matcher/cpsm'])

" Change sorters.
call denite#custom#source(
      \ 'file/rec', 'sorters', ['sorter/sublime'])

" Change default action.
call denite#custom#kind('file', 'default_action', 'split')

" Add custom menus
let s:menus = {}

let s:menus.zsh = {
      \ 'description': 'Edit your import zsh configuration'
      \ }
let s:menus.zsh.file_candidates = [
      \ ['zshrc', '~/.config/zsh/.zshrc'],
      \ ['zshenv', '~/.zshenv'],
      \ ]

let s:menus.my_commands = {
      \ 'description': 'Example commands'
      \ }
let s:menus.my_commands.command_candidates = [
      \ ['Split the window', 'vnew'],
      \ ['Open zsh menu', 'Denite menu:zsh'],
      \ ['Format code', 'FormatCode', 'go,python'],
      \ ]

call denite#custom#var('menu', 'menus', s:menus)

" Ag command on grep source
call denite#custom#var('grep', {
      \ 'command': ['ag'],
      \ 'default_opts': ['-i', '--vimgrep'],
      \ 'recursive_opts': [],
      \ 'pattern_opt': [],
      \ 'separator': ['--'],
      \ 'final_opts': [],
      \ })

" Ack command on grep source
call denite#custom#var('grep', {
      \ 'command': ['ack'],
      \ 'default_opts': [
      \   '--ackrc', $HOME.'/.ackrc', '-H', '-i',
      \   '--nopager', '--nocolor', '--nogroup', '--column'
      \ ],
      \ 'recursive_opts': [],
      \ 'pattern_opt': ['--match'],
      \ 'separator': ['--'],
      \ 'final_opts': [],
      \ })

" Ripgrep command on grep source
call denite#custom#var('grep', {
      \ 'command': ['rg'],
      \ 'default_opts': ['-i', '--vimgrep', '--no-heading'],
      \ 'recursive_opts': [],
      \ 'pattern_opt': ['--regexp'],
      \ 'separator': ['--'],
      \ 'final_opts': [],
      \ })

" Pt command on grep source
call denite#custom#var('grep', {
      \ 'command': ['pt'],
      \ 'default_opts': [
      \   '-i', '--nogroup', '--nocolor', '--smart-case'],
      \ 'recursive_opts': [],
      \ 'pattern_opt': [],
      \ 'separator': ['--'],
      \ 'final_opts': [],
      \ })

" jvgrep command on grep source
call denite#custom#var('grep', {
      \ 'command': ['jvgrep'],
      \ 'default_opts': ['-i'],
      \ 'recursive_opts': ['-R'],
      \ 'pattern_opt': [],
      \ 'separator': [],
      \ 'final_opts': [],
      \ })

" Specify multiple paths in grep source
"call denite#start([{'name': 'grep',
"      \ 'args': [['a.vim', 'b.vim'], '', 'pattern']}])

" Define alias
call denite#custom#alias('source', 'file/rec/git', 'file/rec')
call denite#custom#var('file/rec/git', 'command',
      \ ['git', 'ls-files', '-co', '--exclude-standard'])

call denite#custom#alias('source', 'file/rec/py', 'file/rec')
call denite#custom#var('file/rec/py', 'command',
      \ ['scantree.py', '--path', ':directory'])

" Change ignore_globs
call denite#custom#filter('matcher/ignore_globs', 'ignore_globs',
      \ [ '.git/', '.ropeproject/', '__pycache__/',
      \   'venv/', 'images/', '*.min.*', 'img/', 'fonts/'])

" Custom action
" Note: denite#custom#action() with lambda parameter is only available
"       in NeoVim; not supported in Vim8.
call denite#custom#action('file', 'test',
      \ {context -> execute('let g:foo = 1')})
call denite#custom#action('file', 'test2',
      \ {context -> denite#do_action(
      \  context, 'open', context['targets'])})
" Source specific action
call denite#custom#action('source/file', 'test',
      \ {context -> execute('let g:bar = 1')})
