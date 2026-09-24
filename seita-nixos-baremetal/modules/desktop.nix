{ config, lib, pkgs, ... }:

##############################################################################
# Desktop environment (projector use). Normally headless; KDE Plasma (X11) is
# added for the occasional case of plugging into a projector.
#
# Docs: docs/services/desktop.md (what/why), docs/gpu-driver.md and
# docs/decisions/2026-08-25-projector-hdmi-to-3060ti.md (GPU/display wiring
# history and VRAM contention with modules/comfyui.nix).
#
# When you change this file, update the docs above in the same commit.
##############################################################################
{
  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # X11, not Wayland — see docs/services/desktop.md (projector hot-plug via xrandr/autorandr).
  services.displayManager.defaultSession = "plasmax11";

  # Greeter forced to Xorg too: the sddm module defaults the pre-login greeter
  # to Wayland even when the session is pinned to X11 below, and the greeter
  # is outside the deviceSection BusID pin — caused corrupted projected output
  # at login (2026-08-11). See docs/services/desktop.md.
  services.displayManager.sddm.wayland.enable = false;

  # HDMI output pinned to the RTX 3060 Ti (0000:06:00.0, bus 6). Needed because
  # two NVIDIA cards share one driver and Xorg's card choice is otherwise
  # undefined. History of which card this points at:
  # docs/decisions/2026-08-25-projector-hdmi-to-3060ti.md.
  services.xserver.deviceSection = ''
    BusID "PCI:6:0:0"
  '';

  ############################################################################
  # Sleep/suspend disabled — this host must stay always-on (Minecraft,
  # monitoring, local LLM, n8n). Two layers so PowerDevil can't reintroduce it.
  ############################################################################
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchExternalPower = "ignore";
  services.logind.lidSwitchDocked = "ignore";
  services.logind.extraConfig = ''
    IdleAction=ignore
  '';
}
