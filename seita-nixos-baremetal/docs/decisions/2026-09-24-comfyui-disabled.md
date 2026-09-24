# ComfyUI disabled

- Date: 2026-09-24
- Scope: `modules/comfyui.nix`, `modules/resource-priority.nix`, `modules/reverse-proxy.nix`
- Supersedes: [2026-09-22 ComfyUI stopped by default](2026-09-22-comfyui-disabled-by-default.md)

## Why

ComfyUI was effectively unusable. It is pinned to the RTX 3060 Ti, and since llama.cpp became
always-on (2026-09-23) `bonsai` keeps that card nearly full:

| Measured 2026-09-24 (`nvidia-smi`) | |
|---|---|
| 3060 Ti used / total | 7788 / 8192 MiB (95%) |
| of which `bonsai`'s llama-server | 7678 MiB |

ComfyUI's pre-start VRAM guard refuses to start at 85% or more, and its watch timer force-stops it
at 95%. So with `bonsai` loaded, ComfyUI can never start, and making room means unloading `bonsai`.
Keeping its units, timers, firewall port and Serve route around served no purpose.

## What was done

Reversible, following the "disable, don't delete" rule:

- `modules/comfyui.nix`: new `enable = false;` flag; every unit, timer and the tailscale0 port
  (8188) are wrapped in `lib.mkIf enable`. The `comfyui` system user, its group and the
  `/var/lib/comfyui` tmpfiles rule stay, so the venv and models on `dpool/var/lib/comfyui` keep
  their owner. The module stays imported in `flake.nix`.
- `modules/resource-priority.nix`: the `comfyui-setup` / `comfyui` `serviceConfig` blocks are
  commented out. Leaving them active would still define a `comfyui.service` (with no `ExecStart`)
  — the breakage recorded in
  [2026-09-21](2026-09-21-ollama-serviceconfig-broken-unit.md).
- `modules/reverse-proxy.nix`: the `9443` Serve route is commented out.

The ZFS dataset (`disko/default.nix`) is untouched; data is kept.

## Re-enabling

See [services/comfyui.md](../services/comfyui.md#re-enabling). The VRAM situation above has to
change first, or ComfyUI will still refuse to start.
