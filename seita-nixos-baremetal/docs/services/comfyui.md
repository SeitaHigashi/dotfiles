# ComfyUI

Implementation: [`modules/comfyui.nix`](../../modules/comfyui.nix)

## What it is

Stable Diffusion image generation web UI, installed via `comfy-cli` into a pip venv.
Uses the same NVIDIA GPUs as the other inference services.

- Listen: `0.0.0.0:8188`, reachable only from `tailscale0` (firewall-scoped, same pattern
  as ollama). No Tailscale Serve route yet — likely doesn't support being served from a
  subpath, so a dedicated port would be added in `modules/reverse-proxy.nix` if needed
  (same reasoning as n8n).
- GPU: pinned to the RTX 3060 Ti (`gpuIndex = "1"`, `CUDA_VISIBLE_DEVICES`). VRAM
  contention with llama.cpp's `bonsai` model on the same card:
  [GPU and VRAM budget](../gpu-vram-budget.md).
- **Disabled since 2026-09-24.** No ComfyUI unit, timer, firewall port or Serve route is
  generated (`enable = false` in `modules/comfyui.nix`); the `comfyui` user and
  `/var/lib/comfyui` (venv, models) are kept. Why:
  [2026-09-24 ComfyUI disabled](../decisions/2026-09-24-comfyui-disabled.md).
  Earlier it was only stopped by default
  ([2026-09-22](../decisions/2026-09-22-comfyui-disabled-by-default.md)).

## Re-enabling

1. `modules/comfyui.nix`: `enable = true;`
2. `modules/resource-priority.nix`: uncomment the `comfyui-setup` / `comfyui` blocks.
3. `modules/reverse-proxy.nix`: uncomment the `9443` route.
4. Make room on the 3060 Ti first — with `bonsai` loaded the pre-start guard (85%) refuses
   to start ComfyUI ([GPU and VRAM budget](../gpu-vram-budget.md)).

Doing 1 without 2 generates a `comfyui.service` with no `ExecStart` (the same breakage as
[the ollama case](../decisions/2026-09-21-ollama-serviceconfig-broken-unit.md)).

## Why pip venv, not a nixpkgs package

No `comfyui`/`comfy-cli` package exists in nixpkgs (stable or unstable; confirmed via
`nix search` on 2026-08-05). `comfy-cli` is a PyPI CLI that installs ComfyUI itself into a
venv; Nix here only provides `python3`/`uv` and the systemd units that drive it. This is
the first "pip-venv-managed service" pattern in this repo (later reused by
`modules/llama-cpp.nix`'s Laya and `modules/fukurou.nix`'s Rust-binary pattern is similar
in spirit). Full rationale, including the fixed-user choice
(`comfyui-setup` and `comfyui` share a directory, so `DynamicUser`'s per-invocation UID
would complicate cross-unit permissions) and the dedicated dpool dataset for checkpoints
(`/var/lib/comfyui`, avoiding rpool bloat — the concern is capacity, not the SMR-HDD
write-latency issue that keeps Minecraft on rpool):
[2026-08-05 ComfyUI: pip venv, fixed user, dpool dataset](../decisions/2026-08-05-comfyui-pip-venv.md).

## VRAM contention guard

Because there's no VRAM isolation between GPU workloads on this host, running ComfyUI
alongside a heavy 3060 Ti load risks a driver Xid error that wedges the whole GPU (not
just an OOM) — every process on that card can hang. Since the projector HDMI also landed
on the 3060 Ti (2026-08-25, [decision record](../decisions/2026-08-25-projector-hdmi-to-3060ti.md)),
this risk went up. Policy: "when in doubt, stop ComfyUI, not the other workload."

| Guard | Trigger | Action |
|---|---|---|
| `comfyui-vram-guard pre-start` | GPU1 usage ≥ 85% at start | refuse to start |
| `comfyui-vram-guard watch` (every 30s while running) | usage ≥ 95%, or a recent Xid error in the kernel log | force-stop `comfyui.service` |
| `comfyui-vram-resume` (every 30s, always running) | usage < 70% and the guard's stop-flag is set | restart `comfyui.service` |

The 85/95/70% thresholds are initial guesses — retune if you see false positives or
flapping. A manual `systemctl stop comfyui` does not set the resume flag, so
`comfyui-vram-resume` never interferes with an intentional stop.

## Known risk: untested beyond driver libraries

pip's torch wheel bundles its own CUDA runtime, so in principle only the driver's
userspace libraries (`/run/opengl-driver/lib`, via `LD_LIBRARY_PATH`) should be needed.
But other pip dependencies (e.g. opencv-python) may want non-bundled system libraries like
`libGL.so.1`; if that happens, add the matching nixpkgs package (e.g. `pkgs.libGL`) to the
same `LD_LIBRARY_PATH`. If that's not enough, consider `buildFHSEnv`/`nix-ld` wrapping —
not implemented here. In short: the first `nixos-rebuild switch` plus an actual generation
test is not guaranteed to succeed on the first try; budget at least one debugging pass.

## Model storage

`/var/lib/comfyui/ComfyUI/models/` — dedicated dataset (`dpool/comfyui`,
`recordsize=1M`, `compression=off`). Excluded from snapshots/syncoid replication;
re-download if lost.

## Operating notes

```sh
systemctl status comfyui-setup comfyui comfyui-vram-guard.timer comfyui-vram-resume.timer
journalctl -u comfyui-setup -b     # venv build / comfy install log
journalctl -u comfyui -b | grep -i cuda
ls /run/comfyui-vram-guard/        # guard's stop-flag, if force-stopped
```

Setup/runtime gotchas and their fixes: [runbooks/comfyui.md](../runbooks/comfyui.md).
