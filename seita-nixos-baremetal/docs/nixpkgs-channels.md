# nixpkgs channels: stable/unstable split, unfree packages

## Why the base is stable and only leaf packages come from unstable

You cannot have "kernel on stable, everything else on unstable." Kernel modules
(including ZFS) must be built against the same nixpkgs as the kernel itself —
kernel, ZFS, and kmod are an inseparable set. So instead, the base stays pinned to
stable (`nixos-25.05`), and only leaf, user-facing packages are pulled from
unstable via an overlay (`modules/unstable.nix`):

```nix
nixpkgs.overlays = [
  (final: prev: {
    unstable = import inputs.nixpkgs-unstable { ... };
  })
];
```

Add a package by name to the `unstablePackages` list in `modules/unstable.nix`, or
reference it directly from any module as `pkgs.unstable.<name>`.

**Never put these on unstable:** the kernel or kernel modules
(`linuxPackages*`, `zfs`, the NVIDIA driver), `systemd`, `glibc`, or anything in the
systemd-boot path. All of these lead directly to an unbootable system.

Packages currently pulled from unstable, and why: `mcp-grafana` (not packaged in stable 25.05, used by Claude Code to read Grafana),
`multica-cli` (not in
stable), `opencode` (used as Multica's runtime protocol so ollama's local models
can be reached — the `claude` protocol only talks to the Anthropic API), `nodejs`
(needed to run OpenViking's MCP server via `npx`; stable 25.05 ships 22.x).

Cost of this split: unstable-sourced packages pull unstable-sourced dependencies
too (no sharing with the stable closure), so downloads/builds grow a bit. Fine for
a handful of packages; would add up for something large.

## `nixpkgs-auto`: the auto-updated twin

`nixpkgs-auto` tracks the same `nixos-unstable` branch under its own lock entry and is exposed as
`pkgs.auto.*`. Only this input is bumped by the nightly `nix-auto-update` timer, so the packages that need a
deliberate bump (llama.cpp, llama-swap, …) stay on `pkgs.unstable.*`. On `pkgs.auto`: `open-webui`, `n8n`
(+ its `nodejs`), `neovim` + `vimPlugins`, `herdr`, `rtk`, `brave` (unfree).
See [services/auto-update.md](services/auto-update.md). The "never put these on unstable" list above applies
to it equally.

## The `nixpkgs-unstable` input pin

`flake.nix` pins `nixpkgs-unstable` to a specific revision rather than tracking
`nixos-unstable` directly. See
[2026-09-21 pin nixpkgs-unstable to a cached revision](decisions/2026-09-21-pin-nixpkgs-unstable.md)
for the full incident and the check required before bumping it.

## Unfree packages: allowed by default

This host sets `nixpkgs.config.allowUnfree = true`, defined solely in
`modules/unfree.nix`. Unfree packages need no individual allowance.

Until 2026-10-26 this was an `allowUnfreePredicate` allowlist in the same
file — by name: `nvidia-x11`, `nvidia-settings`, `nvidia-persistenced`,
`n8n`, `open-webui`, `brave`, the Neovim plugins `cmp-calc`, `cmp-emoji`,
`telescope-emoji.nvim`, `presence.nvim`, `codeium` and
`copilot-language-server`; by prefix: `cuda*`, `libcu*`, `libnv*`, plus
`cudnn` and `nccl` — kept narrow so unrelated non-free packages could not
slip in unnoticed.

**A package can be free on one channel and become unfree on another** —
this happened with `open-webui`'s license change, and again when
`nixpkgs-auto` bumped `rtk` 0.50.0 → 1.0.1, whose license gained BSL 1.1.
`rtk` was not on the allowlist, so the nightly `nix-auto-update` failed
evaluation and the channel stalled at the 2026-10-15 revision. Seita
retired the allowlist in favour of the blanket default. The channel's
recovery additionally waits on an upstream fix for `posthog`, marked
broken on the 2026-10-23 revision (one test fails under Python 3.14),
which blocks Open WebUI's build.

There is a second, unrelated unfree toggle: `environment.variables.NIXPKGS_ALLOW_UNFREE = "1"`
in `configuration.nix`, which only affects interactive `nix profile install`/`nix shell`
commands (reads the `NIXPKGS_ALLOW_UNFREE` env var). It has no effect on
`nixos-rebuild`'s evaluation, which consults `nixpkgs.config.allowUnfree`
above — the two are separate code paths.
