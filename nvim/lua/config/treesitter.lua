-- If windows, you should run 'scoop install zig'.
if vim.fn.has('win32') == 1 or vim.fn.has('win64') == 1 then
  require('nvim-treesitter.install').compilers = { "zig" }
end

require'nvim-treesitter.configs'.setup {
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = false,
  },
}
