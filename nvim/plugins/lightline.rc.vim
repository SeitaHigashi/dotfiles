let g:lightline = {
\ 'colorscheme': 'hybrid',
\ 'active': {
\   'left': [ 
\     [ 'mode', 'paste' ],
\     [ 'gitbranch', 'readonly', 'filename', 'modified' ] 
\   ]
\ },
\ 'component_function': {
\   'gitbranch': 'FugitiveHead'
\ },
\ }

