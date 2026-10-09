{ inputs, lib, pkgs, ... }:

##############################################################################
# Neovim plugins are declared in Nix (with their lazy.nvim fields) and Nix
# GENERATES init.lua (inputs.nix-lazy-nvim, lib.mkLazyNvim): every spec carries
# dir = "/nix/store/..."; lazy.nvim only loads them, nothing is cloned.
# Lua modules (lua/config, lsp-configs, keybinds, ...) come from dotfiles/nvim,
# filtered (see configDir below). linkConfig = true links the generated config at ~/.config/nvim.
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
  raw = inputs.nix-lazy-nvim.lib.raw;

  # explicit lazy.nvim name (nixpkgs pnames differ for some), plus lazy fields
  p = name: plugin: extra: { inherit name plugin; } // extra;

  disabledPlugins = [ "gzip" "matchit" "matchparen" "netrwPlugin" "tarPlugin" "rplugin" "tohtml" "tutor" "zipPlugin" ];

  # dotfiles/nvim is shared with non-Nix hosts (Mac/WSL: clone fallback). Those
  # files are replaced here by the generated init.lua + Nix plugin list:
  # init.lua, bootstrap.lua, lazy-options.lua, lua/plugins/ (specs live in the list below),
  # lazy-lock.json.
  nvimRoot = ../nvim;
  configDir = builtins.path {
    name = "nvim-config";
    path = nvimRoot;
    filter = path: type:
      !(builtins.elem (lib.removePrefix (toString nvimRoot + "/") (toString path)) [
        "init.lua"
        "lazy-lock.json"
        "lua/bootstrap.lua"
        "lua/lazy-options.lua"
        "lua/plugins"
      ]);
  };
in
{
  imports = lib.optional enabled inputs.nix-lazy-nvim.homeManagerModules.default;
}
// lib.optionalAttrs enabled {
  programs.nix-lazy-nvim = {
    enable = true;
    package = pkgs.unstable.neovim;
    inherit configDir;
    # xdg.configFile."nvim" -> generated config; nvim then uses ~/.config/nvim and ~/.local/share/nvim. Set false to go back to the private config root.
    linkConfig = true;
    plugins = [
            (p "lazy.nvim" vp.lazy-nvim { version = false; })
  
            # ---- completion ----
            (p "nvim-cmp" vp.nvim-cmp {
              event = "InsertEnter";
              dependencies = [ "lspkind-nvim" "nvim-autopairs" ];
              config = raw "require('config.nvim-cmp')";
            })
            (p "lspkind-nvim" vp.lspkind-nvim { })
            (p "nvim-autopairs" vp.nvim-autopairs { event = "InsertEnter"; opts = { }; })
            (p "LuaSnip" vp.luasnip {
              version = "v2.*";
              build = "make install_jsregexp";
              dependencies = [ "cmp_luasnip" "friendly-snippets" ];
            })
            (p "cmp_luasnip" vp.cmp_luasnip { })
            (p "friendly-snippets" vp.friendly-snippets { })
            (p "cmp-cmdline" vp.cmp-cmdline { event = "CmdlineEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-path" vp.cmp-path { event = "CmdlineEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-nvim-lsp" vp.cmp-nvim-lsp {
              event = "LspAttach";
              dependencies = [ "nvim-cmp" ];
              config = "require('cmp_nvim_lsp').default_capabilities()";
            })
            (p "cmp-nvim-lua" vp.cmp-nvim-lua { ft = "lua"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-rg" vp.cmp-rg { event = "InsertEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-buffer" vp.cmp-buffer { event = "InsertEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-calc" vp.cmp-calc { event = "InsertEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-emoji" vp.cmp-emoji { event = "InsertEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-nerdfont" inputs.nvim-cmp-nerdfont { event = "InsertEnter"; dependencies = [ "nvim-cmp" ]; })
            (p "cmp-treesitter" vp.cmp-treesitter { event = "InsertEnter"; dependencies = [ "nvim-cmp" ]; })
  
            # ---- dap ----
            (p "nvim-dap" vp.nvim-dap { event = "VeryLazy"; })
            (p "mason-nvim-dap.nvim" vp.mason-nvim-dap-nvim {
              dependencies = [ "mason.nvim" "nvim-dap" ];
              event = "VeryLazy";
              opts = { handlers = { }; };
            })
            (p "nvim-nio" vp.nvim-nio { })
            (p "nvim-dap-ui" vp.nvim-dap-ui {
              event = "VeryLazy";
              dependencies = [ "nvim-dap" "nvim-nio" ];
              opts = ''
                local dap, dapui = require("dap"), require("dapui")
                dap.listeners.after.event_initialized["dapui_config"] = function()
                  dapui.open()
                end
                dap.listeners.before.event_terminated["dapui_config"] = function()
                  dapui.close()
                end
                dap.listeners.before.event_exited["dapui_config"] = function()
                  dapui.close()
                end
                return {}
              '';
            })
            (p "telescope-dap.nvim" vp.telescope-dap-nvim { dependencies = [ "nvim-dap" "telescope.nvim" ]; })
  
            # ---- finder ----
            (p "telescope.nvim" vp.telescope-nvim {
              keys = "<Leader>";
              cmd = "Telescope";
              dependencies = [
                "plenary.nvim"
                "telescope-file-browser.nvim"
                "telescope-ui-select.nvim"
                "telescope-frecency.nvim"
                "telescope-emoji.nvim"
                "telescope-lazy.nvim"
                "telescope-luasnip.nvim"
              ];
              config = raw "require('config.telescope')";
            })
            (p "plenary.nvim" vp.plenary-nvim { })
            (p "telescope-file-browser.nvim" vp.telescope-file-browser-nvim { })
            (p "telescope-ui-select.nvim" vp.telescope-ui-select-nvim { })
            (p "telescope-frecency.nvim" vp.telescope-frecency-nvim { })
            (p "telescope-emoji.nvim" vp.telescope-emoji-nvim { })
            (p "telescope-lazy.nvim" inputs.nvim-telescope-lazy { })
            (p "telescope-luasnip.nvim" inputs.nvim-telescope-luasnip { })
  
            # ---- general ----
            (p "nvim-treesitter" vp.nvim-treesitter {
              enabled = raw "not (vim.fn.has('win32') == 1 and vim.fn.has('win64') == 1)";
              build = ":TSUpdate";
              lazy = false;
              branch = "main";
            })
            (p "nvim-treesitter-textobjects" vp.nvim-treesitter-textobjects {
              dependencies = [ "nvim-treesitter" ];
              event = "VeryLazy";
            })
            (p "gitsigns.nvim" vp.gitsigns-nvim {
              dependencies = [ "plenary.nvim" ];
              event = "VeryLazy";
              config = raw "require('config.gitsigns')";
            })
            (p "vim-fugitive" vp.vim-fugitive { event = "VeryLazy"; })
            (p "nightfox.nvim" vp.nightfox-nvim { opts = { transparent = raw "vim.g.transparent_enabled"; }; })
            (p "nvim-surround" vp.nvim-surround { event = "BufEnter"; opts = { }; })
            (p "vim-repeat" vp.vim-repeat { event = "BufEnter"; })
            (p "vim-auto-save" vp.vim-auto-save {
              event = "VeryLazy";
              config = ''
                vim.g.auto_save = 0
                vim.g.auto_save_in_insert_mode = 0
                vim.g.auto_save_silent = 1
              '';
            })
            (p "nvim-web-devicons" vp.nvim-web-devicons { })
            (p "vim-translator" inputs.nvim-vim-translator {
              enabled = raw "require('utils').system_check('python')";
              cmd = [ "Translate" "TranslateH" "TranslateL" "TranslateR" "TranslateW" "TranslateX" ];
              config = ''
                vim.g.translator_target_lang = 'ja'
                vim.g.translator_default_engines = { 'google' }
              '';
            })
            (p "neoterm" vp.neoterm {
              event = [ "CmdlineEnter" "CmdUndefined" ];
              config = ''
                vim.g.neoterm_autoinsert = 0
                vim.g.neoterm_autojump = 1
                vim.g.neoterm_autoscroll = 1
                vim.g.neoterm_default_mod = 'botright'
              '';
            })
            (p "vim-startuptime" vp.vim-startuptime { cmd = "StartupTime"; })
            (p "presence.nvim" vp.presence-nvim {
              enabled = raw "vim.env.HOME_ENV";
              event = "VeryLazy";
              opts = { };
            })
            (p "yuck.vim" vp.yuck-vim { ft = "yuck"; })
  
            # ---- lsp ----
            (p "mason-lspconfig.nvim" vp.mason-lspconfig-nvim {
              dependencies = [ "nvim-lspconfig" "mason.nvim" ];
              event = "VeryLazy";
              opts = { };
            })
            (p "nvim-lspconfig" vp.nvim-lspconfig { })
            (p "mason.nvim" vp.mason-nvim { opts = { }; })
            (p "lspsaga.nvim" vp.lspsaga-nvim {
              cmd = "Lspsaga";
              event = "LspAttach";
              branch = "main";
              dependencies = [ "nvim-web-devicons" "nvim-treesitter" ];
              # nightfox's palette is only on the rtp once lazy.setup has run, so resolve the table lazily
              opts = "return require('config.lspsaga')";
            })
            (p "lsp_signature.nvim" vp.lsp_signature-nvim { event = "InsertEnter"; opts = { }; })
  
            # ---- ui ----
            (p "which-key.nvim" vp.which-key-nvim {
              event = "VeryLazy";
              init = ''
                vim.o.timeout = true
                vim.o.timeoutlen = 300
              '';
              dependencies = [ "nvim-web-devicons" "mini.icons" ];
              opts = raw "require('config.which-key').setup";
            })
            (p "mini.icons" vp.mini-icons { })
            (p "lualine.nvim" vp.lualine-nvim { event = "UIEnter"; config = raw "require('config.lualine')"; })
            (p "noice.nvim" vp.noice-nvim {
              config = raw "require('config.noice')";
              event = "UIEnter";
              dependencies = [ "nui.nvim" "nvim-notify" ];
            })
            (p "nui.nvim" vp.nui-nvim { })
            (p "nvim-notify" vp.nvim-notify { event = "UIEnter"; config = raw "require('config.nvim-notify')"; })
            (p "SmoothCursor.nvim" inputs.nvim-smoothcursor {
              dependencies = [ "lualine.nvim" ];
              event = "VeryLazy";
              opts = ''
                local autocmd = vim.api.nvim_create_autocmd
  
                autocmd({ 'ModeChanged' }, {
                  callback = function()
                    local theme = require('lualine.themes.nordfox')
                    local current_mode = vim.fn.mode()
                    if current_mode == 'n' then
                      vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.normal.a.bg })
                      vim.fn.sign_define('smoothcursor', { text = '' })
                    elseif current_mode == 'v' then
                      vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.visual.a.bg })
                      vim.fn.sign_define('smoothcursor', { text = '󰫙' })
                    elseif current_mode == 'V' then
                      vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.visual.a.bg })
                      vim.fn.sign_define('smoothcursor', { text = '󰿚' })
                    elseif current_mode == '' then
                      vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.visual.a.bg })
                      vim.fn.sign_define('smoothcursor', { text = '󰩬' })
                    elseif current_mode == 'i' then
                      vim.api.nvim_set_hl(0, 'SmoothCursor', { fg = theme.insert.a.bg })
                      vim.fn.sign_define('smoothcursor', { text = '󰗧' })
                    end
                  end,
                })
                return { disable_float_win = true }
              '';
            })
            (p "indent-blankline.nvim" vp.indent-blankline-nvim {
              event = "VeryLazy";
              main = "ibl";
              config = raw "require('config.indent-blankline')";
            })
            (p "quick-scope" vp.quick-scope {
              event = "VeryLazy";
              init = ''
                vim.g.qs_highlight_on_keys = { 'f', 'F' }
                local group = vim.api.nvim_create_augroup('qs_colors', { clear = true })
                vim.api.nvim_create_autocmd('ColorScheme', {
                  pattern = '*',
                  group = group,
                  callback = function()
                    vim.api.nvim_set_hl(0, 'QuickScopePrimary',
                      { fg = '#afff5f', underline = true, ctermfg = 155, cterm = { underline = true } })
                    vim.api.nvim_set_hl(0, 'QuickScopeSecondary',
                      { fg = '#5fffff', underline = true, ctermfg = 81, cterm = { underline = true } })
                  end
                })
              '';
            })
            (p "nvim-bqf" vp.nvim-bqf { ft = "qf"; config = raw "require('config.nvim-bqf')"; })
            (p "auto-hlsearch.nvim" vp.auto-hlsearch-nvim { event = "VeryLazy"; opts = { }; })
            (p "cellular-automaton.nvim" vp.cellular-automaton-nvim { event = "VeryLazy"; })
            (p "transparent.nvim" vp.transparent-nvim { event = "BufEnter"; })
            (p "lsp-lens.nvim" inputs.nvim-lsp-lens { event = "BufReadPre"; opts = { }; })
            (p "markdown.nvim" vp.markdown-nvim {
              ft = "markdown";
              main = "render-markdown";
              opts = { };
              dependencies = [ "nvim-treesitter" "nvim-web-devicons" "mini.icons" ];
            })
  
            # ---- ai ----
            (p "claudecode.nvim" vp.claudecode-nvim {
              dependencies = [ "snacks.nvim" ];
              event = "VeryLazy";
              opts = {
                terminal = { split_width_percentage = 0.40; };
                diff_opts = { keep_terminal_focus = true; };
              };
              keys = [ { _1 = "<leader><leader><leader>"; _2 = "<cmd>ClaudeCode<cr>"; desc = "Toggle Claude"; } ];
            })
            # the old spec put lazy/priority/opts on the dependency entry, which lazy applied to snacks.nvim
            (p "snacks.nvim" vp.snacks-nvim { lazy = false; priority = 1000; opts = { }; })
            (p "sidekick.nvim" vp.sidekick-nvim {
              event = "VeryLazy";
              opts = { cli = { mux = { backend = "zellij"; enabled = true; }; }; };
            })
  
            # conditionally enabled at runtime, but always present in the store (no clone when the condition holds)
            (p "ChatGPT.nvim" vp.ChatGPT-nvim {
              # if OPENAI_API_KEY is not set, this plugin does not load
              enabled = raw "function() return vim.env.OPENAI_API_KEY ~= nil end";
              event = "VeryLazy";
              opts = { };
              dependencies = [ "nui.nvim" "plenary.nvim" "telescope.nvim" ];
            })
            (p "codeium.nvim" vp.codeium-nvim {
              # disabled when free memory is below 1GB
              enabled = raw "function() return require('utils').memory_available() > 1024 and vim.env.HOME_ENV end";
              event = "VeryLazy";
              dependencies = [ "plenary.nvim" "nvim-cmp" ];
              config = ''require("codeium").setup({})'';
            })
            (p "cmp-tabnine" inputs.nvim-cmp-tabnine {
              # disabled when free memory is below 2GB
              enabled = raw "function() return require('utils').memory_available() > 2048 and vim.env.HOME_ENV end";
              event = "InsertEnter";
              config = ''
                require('cmp_tabnine.config'):setup({
                  max_lines = 1000;
                  max_num_results = 20;
                  sort = true;
                  run_on_every_keystroke = true;
                  snippet_placeholder = '..';
                  show_prediction_strength = false;
                })
              '';
            })
            (p "lazygit.nvim" vp.lazygit-nvim {
              enabled = raw "require('utils').system_check('lazygit')";
              event = "VeryLazy";
              dependencies = [ "plenary.nvim" ];
            })
    ];

    # Same order as the old nvim/init.lua: mapleader first; the rest after lazy.setup.
    extraInitLuaPre = ''
      vim.g.mapleader = ' '
    '';
    extraInitLua = ''
      require('lsp-configs')

      if vim.version().minor >= 8 then
        vim.o.cmdheight = 0
      end

      vim.o.laststatus = 3
      vim.o.title = true
      vim.o.expandtab = true
      vim.o.autoindent = true
      vim.o.smartindent = true
      vim.o.shiftwidth = 2
      vim.o.softtabstop = 2
      vim.o.tabstop = 2
      vim.o.showmode = false
      vim.o.background = 'dark'
      vim.o.number = true
      vim.o.relativenumber = true
      vim.o.hidden = true
      vim.o.confirm = true

      if vim.fn.has('termguicolors') then
        vim.o.termguicolors = true
      end

      vim.cmd('colorscheme nordfox')

      vim.cmd 'au BufNewFile,BufRead *.dart setf dart'

      vim.api.nvim_set_hl(0, 'NormalFloat', { sp = Normal })

      require('keybinds')["general"]()
    '';
    lazyOpts = {
      defaults.lazy = true;
      ui = {
        size = { width = 0.85; height = 0.85; };
        border = [ "╭" "─" "╮" "│" "╯" "─" "╰" "│" ];
      };
      performance.rtp.disabled_plugins = raw ''
        (function()
          local l = { ${lib.concatMapStringsSep ", " (n: "'${n}'") disabledPlugins} }
          -- If the system enables python3, rplugin will be enabled.
          if vim.fn.has('python3') == 1 then
            l = vim.tbl_filter(function(v) return v ~= 'rplugin' end, l)
          end
          return l
        end)()
      '';
    };
  };

  # tmux's nordfox theme used to be read from lazy.nvim's clone under
  # ~/.local/share/nvim/lazy (still tried by home.nix); that clone no longer exists.
  programs.tmux.extraConfig = lib.mkBefore ''
    source-file -q ${vp.nightfox-nvim}/extra/nordfox/nordfox.tmux
  '';

  # ---- retired: previous API ($NVIM_NIX_LAZY contract, list of bare plugins + init.lua in
  # dotfiles/nvim). Rollback: remove ./nvim.nix from the imports, or restore this block. ----
  /*
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
  */
}
