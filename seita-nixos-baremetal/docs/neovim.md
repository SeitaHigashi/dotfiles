# Neovim: plugins from Nix, lazy.nvim only loads

Plugins are fetched by Nix; lazy.nvim keeps its loading behaviour (`event` / `cmd` / `ft` / `keys`)
but never clones, updates or checks anything. The Lua config stays in `nvim/` (symlinked at
`~/.config/nvim`, not managed by Nix). Mechanism: <https://github.com/SeitaHigashi/nix-lazy-nvim>.

## Where things live

| What | Where |
|---|---|
| Plugin list, `programs.nix-lazy-nvim` | `../home-manager/nvim.nix` (imported by `home.nix`) |
| Inputs: the module and the git-only plugins | `flake.nix` (`nix-lazy-nvim`, `nvim-*`; pinned by `flake.lock`) |
| Unlicensed plugins | `modules/unfree.nix` |
| Lua side of the contract | `../nvim/lua/bootstrap.lua`, `../nvim/lua/lazy-options.lua` |

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

## Rollback

Remove `./nvim.nix` from `imports` in `home-manager/home.nix` (plain `pkgs.unstable.neovim` returns
automatically); the Lua side falls back to cloning, with `lazy-lock.json` as before.
