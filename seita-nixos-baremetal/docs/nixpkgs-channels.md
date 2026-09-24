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

Packages currently pulled from unstable, and why: `neovim` (newer than stable),
`mcp-grafana` (not packaged in stable 25.05, used by Claude Code to read Grafana),
`brave` (unfree, also listed in `modules/unfree.nix`), `multica-cli` (not in
stable), `opencode` (used as Multica's runtime protocol so ollama's local models
can be reached — the `claude` protocol only talks to the Anthropic API), `nodejs`
(needed to run OpenViking's MCP server via `npx`; stable 25.05 ships 22.x).

Cost of this split: unstable-sourced packages pull unstable-sourced dependencies
too (no sharing with the stable closure), so downloads/builds grow a bit. Fine for
a handful of packages; would add up for something large.

## The `nixpkgs-unstable` input pin

`flake.nix` pins `nixpkgs-unstable` to a specific revision rather than tracking
`nixos-unstable` directly. See
[2026-09-21 pin nixpkgs-unstable to a cached revision](decisions/2026-09-21-pin-nixpkgs-unstable.md)
for the full incident and the check required before bumping it.

## `allowUnfreePredicate`: one place only

`nixpkgs.config.allowUnfreePredicate` is a function, so it can't be merged across
modules — defining it in two places is a hard conflict. Every package that needs
individual unfree allowance is collected in `modules/unfree.nix` (deliberately not
a blanket `allowUnfree = true`, to avoid accidentally pulling in unrelated
non-free packages).

Currently allowed, by name: `nvidia-x11`, `nvidia-settings`, `nvidia-persistenced`
(`modules/gpu.nix`); `n8n` (Sustainable Use License, non-redistributable —
`modules/n8n.nix`); `open-webui` (was MIT through 0.6.x, changed to the proprietary
Open WebUI License — branding-removal and scale restrictions — used via
`modules/ollama.nix`); `brave` (nixpkgs treats it unfree due to the official
build's distribution/trademark terms — `modules/unstable.nix`).

Allowed by prefix, since CUDA packages are numerous and version-churn frequently:
`cuda*` (`cuda_cudart`, `cuda_cccl`, `cuda_nvcc`, ...), `libcu*` (`libcublas`,
`libcurand`, `libcusparse`, ...), `libnv*` (`libnvjitlink`,
`libnvidia-container`, ...), plus `cudnn` and `nccl` by exact name. Still far
narrower than `allowUnfree = true`.

**A package can be free on stable and become unfree on unstable** — this happened
with `open-webui`'s license change. When bumping the unstable pin, re-check
licenses of anything pulled from it.

There is a second, unrelated unfree toggle: `environment.variables.NIXPKGS_ALLOW_UNFREE = "1"`
in `configuration.nix`, which only affects interactive `nix profile install`/`nix shell`
commands (reads the `NIXPKGS_ALLOW_UNFREE` env var). It has no effect on
`nixos-rebuild`'s evaluation, which only consults `allowUnfreePredicate` above — the
two are separate code paths.
