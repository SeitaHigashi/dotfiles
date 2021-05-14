let g:lightline = {
\ 'colorscheme': 'hybrid',
\ 'active': {
\   'left': [ 
\     [ 'mode', 'paste' ],
\     [ 'gitbranch', 'readonly', 'filename', 'modified' ] 
\   ],
\   'right': [
\     ['lineinfo'],
\     ['percent'],
\     ['fileformat', 'fileencoding', 'filetype', 'charvaluehex']
\   ]
\ },
\ 'component_function': {
\   'gitbranch': 'FugitiveHead'
\ },
\ }

