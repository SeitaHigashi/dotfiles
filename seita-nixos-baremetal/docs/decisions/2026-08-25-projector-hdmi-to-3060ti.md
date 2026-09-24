# Projector HDMI: display-card history and the move to the 3060 Ti

- Decided: 2026-08-25 (final move); history starts 2026-08-11.
- Touches: `modules/gpu.nix`, `modules/desktop.nix`, `modules/comfyui.nix`.

## Timeline

1. **2026-08-11**: added a GT1030 (Pascal) as a display-only card for the projector.
   This shifted the 3060 Ti's `CUDA_DEVICE_ORDER=PCI_BUS_ID` index from 1 to 2 while it
   was installed. The SDDM greeter also showed corrupted projected output because the
   greeter renders via Wayland (`kwin_wayland`) by default even when the user session is
   pinned to X11 via `deviceSection`'s `BusID` — the greeter is outside that pin. Fixed by
   also forcing the greeter to Xorg (`services.displayManager.sddm.wayland.enable =
   false`, in `modules/desktop.nix`).
2. **2026-08-12**: removed the GT1030. The 3060 Ti's CUDA index reverted to 1. The
   projector HDMI was connected to the 1660 SUPER (bus 4) instead.
3. **2026-08-25**: moved the projector HDMI from the 1660 SUPER (bus 4) to the 3060 Ti
   (bus 6, PCI address `0000:06:00.0`, confirmed via `/sys/class/drm/card*/status` showing
   `connected`). `modules/desktop.nix`'s `deviceSection` `BusID "PCI:6:0:0"` was updated to
   match. The 1660 SUPER became compute-only.

## Why move the display to the compute+ComfyUI card

No documented reason survives for *why* 08-25's move landed on the 3060 Ti specifically
rather than back on the 1660 SUPER — it is the card ComfyUI is pinned to
(`modules/comfyui.nix`'s `gpuIndex`), so this creates VRAM/compute contention between
Xorg and ComfyUI while projecting that didn't exist before. `comfyui-vram-guard`'s
usage-based checks still catch Xorg's consumption (it just measures `memory.used`), but
the threshold is reached more easily during projection. If this becomes a problem,
consider moving the HDMI back to the 1660 SUPER (now compute-only, no ComfyUI or
llama.cpp `bonsai` model resident there) — trading it off against the 1660 SUPER's own
tight VRAM budget for `embedding`/`laya` (see
[GPU and VRAM budget](../gpu-vram-budget.md)).

## Consequence for GPU index bookkeeping

Because the GT1030 (2026-08-11 → 08-12) temporarily changed the 3060 Ti's CUDA index,
any comment or config value keyed to "GPU index 1 = 3060 Ti" predating 2026-08-12 could be
stale from that window. As of 2026-09-24, only the 1660 SUPER (index 0) and 3060 Ti
(index 1) exist; see [GPU and VRAM budget](../gpu-vram-budget.md) for the current table.
