# Desktop environment (projector)

Implementation: [`modules/desktop.nix`](../../modules/desktop.nix)

## What it is

The host normally runs headless. This module adds KDE Plasma (X11 session) for the
occasional case of plugging it into a projector.

## GPU wiring

The projector HDMI is wired to the RTX 3060 Ti (`BusID "PCI:6:0:0"`), the same card
ComfyUI uses for compute and llama.cpp's `bonsai` model resides on. Both NVIDIA cards
share `services.xserver.videoDrivers = [ "nvidia" ]` from `modules/gpu.nix`, but without
an explicit `BusID`, Xorg's choice of card is undefined — hence pinning it. Full history
of how the display card assignment got here (GT1030 add/remove, HDMI move from the 1660
SUPER): [2026-08-25 projector HDMI moved to the 3060 Ti](../decisions/2026-08-25-projector-hdmi-to-3060ti.md).
GPU/VRAM contention risk while projecting: [GPU and VRAM budget](../gpu-vram-budget.md)
and [gpu-driver.md](../gpu-driver.md).

## X11, not Wayland

The projector is a "plug in occasionally" external output rather than a permanent one.
`xrandr`/`autorandr` have a stronger track record hot-plugging projectors with flaky EDID,
so X11 was chosen for this use case specifically (not a blanket Wayland-vs-X11 verdict for
the host).

## SDDM greeter forced to Xorg too

`services.displayManager.sddm.wayland.enable = false` — NixOS's sddm module defaults the
*greeter* (pre-login screen) to Wayland (`kwin_wayland`) even when the user session itself
is pinned to X11. The greeter isn't covered by the `deviceSection` `BusID` pin, so without
this, GPU selection for the login screen happens outside that pin, and projection during
login was visibly corrupted (observed 2026-08-11, with the GT1030 at the time). Forcing
the greeter to Xorg keeps the same card in use from login screen through session.

## Sleep/suspend disabled

KDE's PowerDevil defaults to allowing suspend/hibernate on idle or lid-close, which is
wrong for an always-on home server (Minecraft, monitoring, local LLM, n8n, etc. all need
to keep running). Disabled at two layers so PowerDevil settings can't reintroduce it:

- `systemd.targets.{sleep,suspend,hibernate,hybrid-sleep}.enable = false`
- `services.logind.lidSwitch*` set to `"ignore"`, plus `IdleAction=ignore`
