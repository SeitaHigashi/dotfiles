# Neovim: plugins declared in Nix, init.lua generated, lazy.nvim only loads

Plugins are declared in Nix together with their lazy.nvim fields (`event` / `cmd` / `ft` / `keys` / `opts` ...);
Nix fetches them **and generates `init.lua`**, where every spec carries `dir = "/nix/store/..."`. lazy.nvim only
loads them: nothing is cloned, updated or checked. With `linkConfig = true` (home-manager) the generated config
(init.lua + `configDir`) is symlinked at `~/.config/nvim` and the wrapper sets no `NVIM_APPNAME`/`XDG_CONFIG_HOME`,
so nvim uses the normal `~/.config/nvim` and `~/.local/share/nvim`.
Mechanism and API (`lib.mkLazyNvim`, `programs.nix-lazy-nvim`): <https://github.com/SeitaHigashi/nix-lazy-nvim>.

## Where things live

| What | Where |
|---|---|
| Plugin list (with lazy fields), options, `programs.nix-lazy-nvim` | `../home-manager/nvim.nix` (imported by `home.nix`) |
| Inputs: the module and the git-only plugins | `flake.nix` (`nix-lazy-nvim`, `nvim-*`; pinned by `flake.lock`) |
| Unlicensed plugins | `modules/unfree.nix` |
| Lua modules (`lua/config/*`, `lsp-configs`, `keybinds`, `utils`, `lsp/`) | `../nvim/` (shared with Mac/WSL) |

## How it works

`configDir` is `../nvim` filtered to drop what the generated init.lua replaces: `init.lua`, `lazy-lock.json`,
`lua/bootstrap.lua`, `lua/lazy-options.lua`, `lua/plugins/`. The old `init.lua` lines were moved into
`extraInitLuaPre` (`mapleader`) and `extraInitLua` (everything after `lazy.setup`: `lsp-configs`, `vim.o.*`,
`colorscheme nordfox`, keybinds), in their original order. `lazy-options.lua` became `lazyOpts`.
Plugin config is `raw "require('config.xxx')"` or inline Lua strings in `nvim.nix`.

**Known cost: plugin specs exist twice.** The Nix list in `nvim.nix` (this host) and `nvim/lua/plugins/*.lua`
(Mac/WSL, which still clone via `bootstrap.lua` + `lazy-lock.json`) are maintained by hand; there is no sync
mechanism. Changing a plugin means editing both. (`bootstrap.lua` / `lazy-options.lua` still contain the old
`$NVIM_NIX_LAZY` branch; it is dead code now and harmless for Mac/WSL.)

## Operating notes

- Add a plugin: add `(p "name" vp.foo-nvim { ...lazy fields })` to `plugins` in `nvim.nix` (or a `flake = false`
  input for git-only plugins) **and** a spec to `nvim/lua/plugins/` for Mac/WSL. `p` sets the lazy.nvim name explicitly
  (nixpkgs pnames can differ, e.g. `LuaSnip`, `lspkind-nvim`).
- Update: `nix flake update nixpkgs-unstable` (or `nix-lazy-nvim`, one `nvim-*` input). `lazy-lock.json` is unused under Nix.
- Plugins come from `pkgs.unstable.vimPlugins` (nvim-treesitter `main`, telescope-frecency need unstable).
- Non-nixpkgs: `cmp-tabnine` (removed from nixpkgs) is a `flake = false` input; its binary (`install.sh`) is **not** fetched, so it
  only works if a binary is placed manually. `codeium.nvim` needs `"codeium"` in `modules/unfree.nix`
  (nixpkgs `vimPlugins.codeium-nvim` now evaluates to windsurf.nvim and warns).
- `lspsaga.nvim` `opts` is a lazy function (`return require('config.lspsaga')`) because nightfox is not on the rtp at spec time.
- Not covered: `build =` steps (`:TSUpdate`, `make install_jsregexp`) are not run; Mason still downloads binaries at run time.
- `programs.nix-lazy-nvim` ships its own `nvim`; `home.nix` skips plain neovim when it is enabled.
- tmux's nordfox theme is sourced from the store path of the nightfox plugin (`nvim.nix`).
- Verification: dump script in `~/nvim-migrate-verify/` (`run.sh <nvim> <out>`, `dump.lua`) lists plugins and options for diffing.

## Config location and data dir

`~/.config/nvim` -> `/nix/store/...-nvim-config-root/nix-lazy-nvim` (managed by `xdg.configFile."nvim"`). Activation
fails if a real `~/.config/nvim` already exists (move it away first; the old `dotfiles/nvim` symlink must be removed).
The data dir is now `~/.local/share/nvim` (before: `~/.local/share/nix-lazy-nvim`), so Mason binaries and lazy state
start empty. Nothing else in the dotfiles (`setting.sh` only touches the legacy packer dir) manages `~/.config/nvim`.

## Rollback

`linkConfig = false;` in `nvim.nix` restores the private config root (`NVIM_APPNAME=nix-lazy-nvim`, data in
`~/.local/share/nix-lazy-nvim`). Or:

Remove `./nvim.nix` from `imports` in `home-manager/home.nix` (plain `pkgs.unstable.neovim` returns automatically;
re-create `~/.config/nvim` -> `dotfiles/nvim` by hand to clone-load as on Mac/WSL). The previous `nvim.nix` is kept as a
comment at the bottom of the file; the previous API also needs the old `nix-lazy-nvim` revision (`1712903`) in `flake.lock`.

<!-- Retired (previous API: $NVIM_NIX_LAZY contract)
## How it works

The wrapper `nvim` exports `$NVIM_NIX_LAZY` (a Lua file returning `{ lazypath, opts }`).
`bootstrap.lua` uses it for lazy.nvim's path; `lazy-options.lua` merges `opts`
(`dev = { path = <store dir>, patterns = { "" }, fallback = false }`, `install.missing = false`, ...).
A plugin missing from the Nix list therefore fails at startup instead of being cloned.
Without the variable (Mac / WSL, or the old `nvim`) the config clones plugins as before, using `lazy-lock.json`.

## Operating notes

- Add a plugin: add it to the `plugins` list (or `extraPlugins` plus a `flake = false` input if it is not in
  nixpkgs) **and** to `nvim/lua/plugins/`. The lazy.nvim name must match (`vp.foo-nvim` has pname `foo.nvim`;
  override with `{ name = "..."; plugin = ...; }` when they differ, as for `LuaSnip` and `lspkind-nvim`).
- Update: `nix flake update nixpkgs-unstable` (or one `nvim-*` input). `lazy-lock.json` is no longer used under Nix.
- Plugins come from `pkgs.unstable.vimPlugins`: nvim-treesitter's `main` branch and telescope-frecency are not in stable.
- Treesitter grammars are `dependencies` of `nvim-treesitter.withAllGrammars`; the module merges them into one dir.
- Not covered: `build =` steps (`:TSUpdate`, `make install_jsregexp`) are not run, and Mason still downloads
  binaries at run time (may not work on NixOS).
- `programs.nix-lazy-nvim` ships its own `nvim`; `home.nix` skips plain neovim when it is enabled.
- tmux's nordfox theme is sourced from the store path of the nightfox plugin (the lazy.nvim clone is gone).

-->
