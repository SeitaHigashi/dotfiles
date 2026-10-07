-- Under Nix (seita-nixos-baremetal/modules/nvim.nix) plugins and lazy.nvim itself come from the
-- store: $NVIM_NIX_LAZY points at a Lua file returning { lazypath, opts }. Without it, clone as before.
local nix = os.getenv('NVIM_NIX_LAZY') and dofile(os.getenv('NVIM_NIX_LAZY'))
_G.nix_lazy = nix

local lazypath = nix and nix.lazypath or (vim.fn.stdpath("data") .. "/lazy/lazy.nvim")
if not nix and not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    -- "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)
