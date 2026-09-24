{ config, lib, pkgs, ... }:

##############################################################################
# NVIDIA GPU driver (proprietary), shared by ollama/ComfyUI (CUDA) and the
# nvidia-gpu-exporter (modules/monitoring.nix).
#
# Docs (history, measurements, caller-facing notes are not comments — see here):
#   docs/gpu-driver.md                       driver package choice, display wiring,
#                                             ldconfig shim, power limit, two-card caveats
#   docs/gpu-vram-budget.md                  VRAM per card, per-service
#   docs/decisions/2026-08-25-projector-hdmi-to-3060ti.md
#   docs/decisions/2026-09-23-3060ti-power-limit.md
#   docs/runbooks/gpu.md                     driver version bump, GPU swap procedure
#
# When you change this file, update the docs above in the same commit.
##############################################################################

{
  # allowUnfreePredicate lives in modules/unfree.nix (covers NVIDIA/CUDA).

  ############################################################################
  # Driver. videoDrivers = [ "nvidia" ] is required even headless (X is not
  # started unless services.xserver.enable = true elsewhere).
  ############################################################################
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics.enable = true;

  hardware.nvidia = {
    # beta, not production: required by ollama-cuda's CUDA 12.9 (docs/gpu-driver.md).
    # ★ If a rebuild fails on the nvidia driver, revert to `production` and also
    #   revert modules/ollama.nix's package to stable pkgs.ollama-cuda (docs/gpu-driver.md).
    package = config.boot.kernelPackages.nvidiaPackages.beta;

    # Proprietary kernel module, not open — see docs/gpu-driver.md.
    open = false;

    modesetting.enable = true;

    # Keeps the driver initialized between GPU users; avoids reinit cost and
    # metric gaps on the 30s monitoring poll.
    nvidiaPersistenced = true;

    # Laptop feature; irrelevant/risky on an always-on desktop server.
    powerManagement.enable = false;
  };

  ############################################################################
  # /sbin/ldconfig compatibility shim.
  #
  # NixOS has no /sbin/ldconfig. triton (torch's CUDA JIT) shells out to this
  # absolute path directly, so a systemd unit's `path` can't fix it — the file
  # must exist on disk. Same pattern likely needed by other CUDA Python
  # packages (xformers, bitsandbytes), so it lives here rather than in
  # modules/comfyui.nix. Details: docs/gpu-driver.md.
  ############################################################################
  systemd.tmpfiles.rules = [
    "d /sbin 0755 root root -"
    "L+ /sbin/ldconfig - - - - ${pkgs.glibc.bin}/bin/ldconfig"
  ];

  ############################################################################
  # RTX 3060 Ti power limit (fan noise). Watts, not temperature/clock — the
  # relationship and the chosen 105 W are measured in
  # docs/decisions/2026-09-23-3060ti-power-limit.md.
  #
  # ★ Volatile: resets on driver reload/reboot even with persistenced, hence
  #   this systemd unit re-applies it every boot. GPU 1 = RTX 3060 Ti (see
  #   docs/gpu-driver.md's card table; 1660 SUPER is left uncapped).
  ############################################################################
  systemd.services.nvidia-power-limit = {
    description = "Cap the RTX 3060 Ti power limit to reduce fan noise";
    after = [ "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -i 1 -pl 105";
      ExecStop = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -i 1 -pl 200";
    };
  };

  # Operational commands and the driver-version-mismatch-after-switch gotcha:
  # docs/runbooks/gpu.md.
}
