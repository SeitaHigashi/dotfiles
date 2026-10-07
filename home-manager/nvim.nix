{ inputs, lib, pkgs, ... }:

##############################################################################
# Neovim plugins are fetched by Nix and lazy.nvim only loads them
# (inputs.nix-lazy-nvim; contract: $NVIM_NIX_LAZY, read by nvim/lua/bootstrap.lua).
# The Lua config itself stays in dotfiles/nvim, symlinked at ~/.config/nvim.
# Details and rollback: seita-nixos-baremetal/docs/neovim.md
#
# Active only where the flake provides inputs.nix-lazy-nvim (seita-nixos-baremetal)
# and pkgs.unstable; elsewhere home.nix keeps installing plain neovim.
# Plugins come from nixpkgs-unstable: nvim-treesitter's main branch and
# telescope-frecency (needs nvim >= 0.11.7) are not in stable. Unlicensed
# plugins are allowlisted in seita-nixos-baremetal/modules/unfree.nix.
#
# Gated on `inputs` only (never on pkgs/config) to avoid infinite recursion.
##############################################################################

let
  enabled = inputs ? nix-lazy-nvim;
  vp = pkgs.unstable.vimPlugins;
in
{
  imports = lib.optional enabled inputs.nix-lazy-nvim.homeManagerModules.default;
}
// lib.optionalAttrs enabled {
  programs.nix-lazy-nvim = {
    enable = true;
    package = pkgs.unstable.neovim;
    plugins = [
      vp.lazy-nvim
      # lazy.nvim names differ from the nixpkgs pnames for these two
      { name = "LuaSnip"; plugin = vp.luasnip; }
      { name = "lspkind-nvim"; plugin = vp.lspkind-nvim; }
      vp.auto-hlsearch-nvim
      vp.cellular-automaton-nvim
      vp.claudecode-nvim
      vp.cmp-buffer
      vp.cmp-calc
      vp.cmp-cmdline
      vp.cmp-emoji
      vp.cmp-nvim-lsp
      vp.cmp-nvim-lua
      vp.cmp-path
      vp.cmp-rg
      vp.cmp-treesitter
      vp.cmp_luasnip
      vp.friendly-snippets
      vp.gitsigns-nvim
      vp.indent-blankline-nvim
      vp.lsp_signature-nvim
      vp.lspsaga-nvim
      vp.lualine-nvim
      vp.markdown-nvim
      vp.mason-lspconfig-nvim
      vp.mason-nvim-dap-nvim
      vp.mason-nvim
      vp.mini-icons
      vp.neoterm
      vp.nightfox-nvim
      vp.noice-nvim
      vp.nui-nvim
      vp.nvim-autopairs
      vp.nvim-bqf
      vp.nvim-cmp
      vp.nvim-dap
      vp.nvim-dap-ui
      vp.nvim-lspconfig
      vp.nvim-nio
      vp.nvim-notify
      vp.nvim-surround
      vp.nvim-treesitter
      vp.nvim-treesitter-textobjects
      vp.nvim-web-devicons
      vp.plenary-nvim
      vp.presence-nvim
      vp.quick-scope
      vp.sidekick-nvim
      vp.snacks-nvim
      vp.telescope-dap-nvim
      vp.telescope-emoji-nvim
      vp.telescope-file-browser-nvim
      vp.telescope-frecency-nvim
      vp.telescope-ui-select-nvim
      vp.telescope-nvim
      vp.transparent-nvim
      vp.vim-auto-save
      vp.fugitive
      vp.repeat
      vp.vim-startuptime
      vp.which-key-nvim
      vp.yuck-vim
    ];
    # Not in nixpkgs: git-only plugins pinned through flake.lock
    extraPlugins = {
      "SmoothCursor.nvim" = inputs.nvim-smoothcursor;
      "cmp-nerdfont" = inputs.nvim-cmp-nerdfont;
      "lsp-lens.nvim" = inputs.nvim-lsp-lens;
      "telescope-lazy.nvim" = inputs.nvim-telescope-lazy;
      "telescope-luasnip.nvim" = inputs.nvim-telescope-luasnip;
      "vim-translator" = inputs.nvim-vim-translator;
    };
  };

  # tmux's nordfox theme used to be read from lazy.nvim's clone under
  # ~/.local/share/nvim/lazy (still tried by home.nix); that clone no longer exists.
  programs.tmux.extraConfig = lib.mkBefore ''
    source-file -q ${vp.nightfox-nvim}/extra/nordfox/nordfox.tmux
  '';
}
