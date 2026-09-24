# GPU driver (NVIDIA)

Implementation: [`modules/gpu.nix`](../modules/gpu.nix). Also touches
[`modules/desktop.nix`](../modules/desktop.nix) (X11 output card) and
[`modules/comfyui.nix`](../modules/comfyui.nix) (compute card, `/sbin/ldconfig` shim
consumer). VRAM budgeting and per-card workload assignment live in
[GPU and VRAM budget](gpu-vram-budget.md) — this doc is the cross-cutting driver/display
plumbing, not VRAM numbers.

## Cards

| index (`CUDA_DEVICE_ORDER=PCI_BUS_ID`) | Card | PCI | Role |
|---|---|---|---|
| 0 | GTX 1660 SUPER (Turing TU116, no FP16 tensor cores) | `0000:04:00.0`, PCIe x4 | compute only |
| 1 | RTX 3060 Ti (Ampere GA104) | `0000:06:00.0`, PCIe x8 | compute + display (HDMI) |

One driver (`hardware.nvidia`) covers both generations. Combined compute VRAM is 14 GiB
(6+8). See [GPU and VRAM budget](gpu-vram-budget.md) for what's resident where.

### Display-card history

A third card (GT1030, display-only) was added 2026-08-11 and removed 2026-08-12; while
present it shifted the 3060 Ti's CUDA index from 1 to 2. The projector HDMI was on the
1660 SUPER from 2026-08-12, then moved to the 3060 Ti on 2026-08-25. Full history and the
consequences for `comfyui-vram-guard` and `modules/desktop.nix`'s `BusID` pin:
[2026-08-25 projector HDMI moved to the 3060 Ti](decisions/2026-08-25-projector-hdmi-to-3060ti.md).

### Two-card inference caveats

Splitting a model's layers across both cards is not guaranteed to be faster — it's a
fallback, not a default:

- The slower card (1660 SUPER) is the bottleneck for layer-split inference.
- The 1660 SUPER is Turing but the TU116 die has no FP16 tensor cores, unlike the 3060
  Ti's Ampere cores — the generation gap understates the real performance gap.
- Measured PCIe link width is x4 (1660 SUPER) / x8 (3060 Ti), both physically x16.
  Layer-split transfers between cards are hurt by the slower card also having the
  narrower link. Check with:
  `nvidia-smi --query-gpu=name,pcie.link.width.current --format=csv`
- The 3060 Ti also carries Xorg's VRAM/compute load while projecting, and it's
  ComfyUI's dedicated compute card (`modules/comfyui.nix`'s `gpuIndex`), so contention
  risk is higher during projection.

Removing the 1660 SUPER and running the 3060 Ti alone may well be faster. Check the
Grafana "GPU usage (per card)" panel when loading a model that spans both.

## Driver package: beta, not production

Using `hardware.nvidia.package = config.boot.kernelPackages.nvidiaPackages.beta`
(575.51.02) instead of the usual `production` (570.195.03) track, because
`modules/ollama.nix`'s unstable `ollama-cuda` pulls CUDA 12.9 userspace libraries, while
NixOS 25.05's production/latest/stable tracks are all CUDA-12.8-era (570.x). Minor-version
compatibility likely covers this, but any 12.9-only API used at runtime would fail, and an
inference host isn't the place to bet on that.

Trade-off: beta breaks more often across kernel updates than production. **If a rebuild
fails on the nvidia driver build, revert this to `production` and also revert
`modules/ollama.nix`'s package to the stable `pkgs.ollama-cuda`** (CUDA 12.8 on both
sides). Turing (1660 SUPER) and Ampere (3060 Ti) are both covered by either track.

## `open = false`

Not using the open-source kernel module. Turing (1660 SUPER) sits near the open-driver
support boundary and the proprietary driver has a longer track record there. Revisit
`open = true` if the 1660 SUPER is ever removed (3060 Ti alone).

## `nvidiaPersistenced = true`

Without persistence mode, the driver unloads whenever no process is using the GPU, and
every `nvidia-smi` call (monitoring polls every 30s) pays reinitialization cost and can
show a metrics gap.

## `powerManagement.enable = false`

This is a laptop feature (suspend/resume power management); on an always-on desktop
server it only risks introducing suspend-resume bugs.

## `/sbin/ldconfig` compatibility shim

NixOS has no `/sbin/ldconfig` — shared-library resolution goes through Nix store rpaths,
so glibc's ldconfig is unneeded at the OS level. But `triton` (torch's CUDA kernel JIT)
looks up CUDA libraries by shelling out to the absolute path `/sbin/ldconfig -p`, and
without the file it fails with `FileNotFoundError`. Confirmed via ComfyUI
(`modules/comfyui.nix`). Because this is an absolute-path call, a systemd unit's `path =
[...]` (PATH search) can't fix it — the file has to exist on disk:

```nix
systemd.tmpfiles.rules = [
  "d /sbin 0755 root root -"
  "L+ /sbin/ldconfig - - - - ${pkgs.glibc.bin}/bin/ldconfig"
];
```

Placed here (GPU/CUDA foundation) rather than in `comfyui.nix`, since other CUDA Python
packages (xformers, bitsandbytes) are known to have the same absolute-path pattern.

## 3060 Ti power limit (fan noise)

Capped at 105 W via `nvidia-power-limit.service` (`nvidia-smi -i 1 -pl 105`, restored to
200 W on stop since the setting doesn't survive a driver reload). Rationale and the full
measurement table: [2026-09-23 3060 Ti power limit for fan noise](decisions/2026-09-23-3060ti-power-limit.md).

**This is watts, not degrees** — the fan follows power draw almost linearly (~1%/W from
95–137 W) because the card holds GPU Target Temperature (83°C) via clock speed, not fan
curve. `nvidia-smi -lgc` (clock lock) was considered and rejected: it has 20+ points of
fan hysteresis after a load spike that `-pl` doesn't.

Setting is volatile — persistenced does not preserve it across a reboot, hence the
systemd unit (`nvidia-power-limit`).

## Operational notes

```sh
nvidia-smi -L                                                   # card count/model
nvidia-smi topo -m                                               # PCIe topology
nvidia-smi --query-gpu=pcie.link.width.current --format=csv      # link width
nvidia-smi                                                        # live usage
```

A driver install/version change (kernel module) requires a **reboot**, not just
`nixos-rebuild switch` — `nixos-rebuild switch` alone often leaves `nvidia-smi` unable to
initialize. When bumping the driver version (e.g. 570 → 575), the running kernel module
stays old until reboot while `nvidia-smi` (userspace) is already new, producing
`Failed to initialize NVML: Driver/library version mismatch` for
`nvidia-gpu-exporter` and any CUDA workload (ollama falls back to CPU) until reboot.

Runbook for driver/GPU-swap procedures: [runbooks/gpu.md](runbooks/gpu.md).
