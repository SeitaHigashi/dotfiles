{ config, lib, pkgs, ... }:

##############################################################################
# ComfyUI (Stable Diffusion image-generation web UI), installed via comfy-cli
# into a pip venv. Uses the same NVIDIA GPU as ollama/llama.cpp.
#
# Docs (history, measurements, caller-facing notes are not comments — see here):
#   docs/services/comfyui.md                 what it is, ports, VRAM guard, disabled-by-default
#   docs/runbooks/comfyui.md                 setup/runtime gotchas hit on real hardware
#   docs/gpu-vram-budget.md                  VRAM budget shared with llama.cpp/fukurou
#   docs/decisions/2026-08-05-comfyui-pip-venv.md         pip venv / fixed user / dpool dataset
#   docs/decisions/2026-08-08-comfyui-disable-dynamic-vram.md
#   docs/decisions/2026-09-22-comfyui-disabled-by-default.md
#   docs/decisions/2026-08-25-projector-hdmi-to-3060ti.md  why GPU1 also carries Xorg
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  port = 8188;
  stateDir = "/var/lib/comfyui";
  gpuIndex = "1"; # RTX 3060 Ti — see docs/gpu-vram-budget.md for the current index table

  # VRAM usage thresholds (%). Hysteresis avoids flapping near the boundary.
  startBlockPct = 85; # pre-start check: refuse to start at/above this
  stopPct = 95;        # continuous watch: force-stop at/above this
  resumePct = 70;      # auto-resume: resume below this

  flagDir = "/run/comfyui-vram-guard";
  flagFile = "${flagDir}/stopped-by-guard";

  nvidiaSmi = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi";

  usagePctScript = ''
    ${nvidiaSmi} --query-gpu=memory.used,memory.total \
      --format=csv,noheader,nounits -i ${gpuIndex} \
      | awk -F', *' '{ printf "%d", ($1 / $2) * 100 }'
  '';

  vramGuard = pkgs.writeShellApplication {
    name = "comfyui-vram-guard";
    runtimeInputs = [ pkgs.gawk pkgs.gnugrep pkgs.systemd pkgs.coreutils ];
    text = ''
      set -euo pipefail

      mode="''${1:?usage: comfyui-vram-guard pre-start|watch}"

      pct=$(${usagePctScript})

      has_recent_xid() {
        journalctl -k --since "-1min" --no-pager 2>/dev/null | grep -qi "Xid"
      }

      case "$mode" in
        pre-start)
          if [ "$pct" -ge ${toString startBlockPct} ]; then
            echo "comfyui-vram-guard: GPU${gpuIndex} used ''${pct}%% (>= ${toString startBlockPct}%%), refusing to start" >&2
            exit 1
          fi
          ;;
        watch)
          if [ "$pct" -ge ${toString stopPct} ] || has_recent_xid; then
            echo "comfyui-vram-guard: GPU${gpuIndex} used ''${pct}%%, stopping comfyui.service" >&2
            mkdir -p "${flagDir}"
            touch "${flagFile}"
            systemctl stop comfyui.service
          fi
          ;;
        *)
          echo "unknown mode: $mode" >&2
          exit 1
          ;;
      esac
    '';
  };

  vramResume = pkgs.writeShellApplication {
    name = "comfyui-vram-resume";
    runtimeInputs = [ pkgs.gawk pkgs.systemd pkgs.coreutils ];
    text = ''
      set -euo pipefail

      [ -e "${flagFile}" ] || exit 0

      pct=$(${usagePctScript})

      if [ "$pct" -lt ${toString resumePct} ]; then
        rm -f "${flagFile}"
        systemctl start comfyui.service
      fi
    '';
  };
in
{
  ############################################################################
  # Execution user (same fixed-system-user pattern as discord-bot; see
  # docs/decisions/2026-08-05-comfyui-pip-venv.md for why not DynamicUser).
  ############################################################################
  users.users.comfyui = {
    isSystemUser = true;
    group = "comfyui";
    home = stateDir;
  };
  users.groups.comfyui = { };

  # Dataset mount is root-owned right after mounting; fix ownership
  # declaratively. 'd' only adjusts an existing directory's owner/mode, it
  # never deletes contents.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0750 comfyui comfyui - -"
  ];

  ############################################################################
  # venv setup (install comfy-cli, install ComfyUI itself).
  #
  # Idempotent: creates the venv if missing, always updates comfy-cli (-U),
  # only installs ComfyUI if main.py is missing.
  ############################################################################
  systemd.services.comfyui-setup = {
    description = "ComfyUI venv setup (comfy-cli)";
    before = [ "comfyui.service" ];

    # comfy-cli imports GitPython (workspace_manager.py) at import time and
    # dies with ImportError if `git` isn't on PATH (see docs/runbooks/comfyui.md).
    path = [ pkgs.git ];

    # install also runs CUDA detection, so it needs the same library/GPU-order
    # fixes as comfyui.service below.
    environment = {
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
      CUDA_VISIBLE_DEVICES = gpuIndex;
      LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc ] + ":/run/opengl-driver/lib";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "comfyui";
      Group = "comfyui";
      WorkingDirectory = stateDir;
    };

    script = ''
      set -euo pipefail

      if [ ! -x ${stateDir}/venv/bin/python ]; then
        ${pkgs.uv}/bin/uv venv --python ${pkgs.python3}/bin/python3 ${stateDir}/venv
      fi

      ${pkgs.uv}/bin/uv pip install --python ${stateDir}/venv/bin/python -U comfy-cli

      if [ ! -f ${stateDir}/ComfyUI/main.py ]; then
        ${stateDir}/venv/bin/comfy --workspace ${stateDir}/ComfyUI --skip-prompt install --nvidia
      fi

      # ComfyUI's own venv (ComfyUI/.venv) has no pip (docs/runbooks/comfyui.md).
      if ! ${stateDir}/ComfyUI/.venv/bin/python -m pip --version >/dev/null 2>&1; then
        ${stateDir}/ComfyUI/.venv/bin/python -m ensurepip --upgrade
      fi

      # ComfyUI-Manager auto-detects use_uv=true and then fails to start —
      # force it off explicitly. Full explanation: docs/runbooks/comfyui.md.
      ${pkgs.python3}/bin/python3 -c '
import configparser, os
path = "${stateDir}/ComfyUI/user/__manager/config.ini"
os.makedirs(os.path.dirname(path), exist_ok=True)
c = configparser.ConfigParser()
if os.path.exists(path):
    c.read(path)
if "default" not in c:
    c["default"] = {}
c["default"]["use_uv"] = "false"
with open(path, "w") as f:
    c.write(f)
'
    '';
  };

  ############################################################################
  # Server
  ############################################################################
  systemd.services.comfyui = {
    description = "ComfyUI server";
    after = [ "comfyui-setup.service" "nvidia-persistenced.service" ];
    wants = [ "comfyui-setup.service" "nvidia-persistenced.service" "comfyui-vram-guard.timer" ];
    requires = [ "comfyui-setup.service" ];

    ########################################################################
    # ★ Disabled by default since 2026-09-22 (wantedBy = []) ★ frees the
    #   3060 Ti's VRAM for llama.cpp's model. Keep the module wired in
    #   flake.nix regardless (removing it breaks modules/resource-priority.nix's
    #   reference — see docs/decisions/2026-09-22-comfyui-disabled-by-default.md).
    #   Start manually: sudo systemctl start comfyui
    #   To restore always-on, revert this and comfyui-vram-resume.timer's
    #   wantedBy back to [ "multi-user.target" ].
    ########################################################################
    wantedBy = [ ];

    # Needs git (GitPython, same as setup) and uv (comfy-cli shells out to
    # `uv pip freeze` via PATH at launch) and gcc (triton compiles kernels at
    # runtime and needs a C compiler). See docs/runbooks/comfyui.md.
    path = [ pkgs.git pkgs.uv pkgs.gcc ];

    environment = {
      # CUDA_DEVICE_ORDER=PCI_BUS_ID forces nvidia-smi's numbering (else CUDA's
      # FASTEST_FIRST default picked the 1660 SUPER instead of index "1" as
      # intended — confirmed on real hardware). Keeps this aligned with what
      # comfyui-vram-guard queries via `nvidia-smi -i 1`. See docs/runbooks/comfyui.md.
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
      CUDA_VISIBLE_DEVICES = gpuIndex;
      # libstdc++ is missing on NixOS (no /usr/lib); pip's torch needs it for
      # torch._C. See docs/runbooks/comfyui.md.
      LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.stdenv.cc.cc ] + ":/run/opengl-driver/lib";

      # triton locates libcuda.so via `/sbin/ldconfig -p`, which fails on
      # NixOS (no ld.so.cache) even with the /sbin/ldconfig shim
      # (modules/gpu.nix). This bypasses ldconfig lookup entirely.
      TRITON_LIBCUDA_PATH = "/run/opengl-driver/lib";
      CC = "${pkgs.gcc}/bin/gcc";

      # triton also needs ptxas/cuobjdump/nvdisasm, not bundled with pip's
      # torch/triton. Pointed at the matching cudaPackages derivations
      # (allowUnfreePredicate covers the "cuda" prefix, modules/gpu.nix).
      TRITON_PTXAS_PATH = "${pkgs.cudaPackages.cuda_nvcc}/bin/ptxas";
      TRITON_CUOBJDUMP_PATH = "${pkgs.cudaPackages.cuda_cuobjdump}/bin/cuobjdump";
      TRITON_NVDISASM_PATH = "${pkgs.cudaPackages.cuda_nvdisasm}/bin/nvdisasm";
    };

    serviceConfig = {
      Type = "simple";
      User = "comfyui";
      Group = "comfyui";
      WorkingDirectory = stateDir;

      # Refuse to start if ollama/llama.cpp is already heavily using GPU1.
      ExecStartPre = "${vramGuard}/bin/comfyui-vram-guard pre-start";

      # --disable-dynamic-vram: comfy-aimdo hung completely (not OOM) on an
      # over-VRAM model (2026-08-08, upstream Comfy-Org/ComfyUI#15255).
      # Trade-off: oversized models now fail with a plain CUDA OOM instead.
      # See docs/decisions/2026-08-08-comfyui-disable-dynamic-vram.md.
      ExecStart = "${stateDir}/venv/bin/comfy --workspace ${stateDir}/ComfyUI launch -- --listen 0.0.0.0 --port ${toString port} --disable-dynamic-vram";

      # A guard-triggered `systemctl stop` counts as intentional (systemd
      # semantics), so it's not covered by Restart=. This is a crash-only safety net.
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  ############################################################################
  # VRAM contention guard — continuous watch + pre-start check.
  #
  # The timer's PartOf = comfyui.service means this monitoring stops whenever
  # comfyui.service stops (including a guard-triggered stop). comfyui.service's
  # `wants` brings it up together at start.
  ############################################################################
  systemd.services.comfyui-vram-guard = {
    description = "Stop comfyui if GPU VRAM contention risks a driver hang";
    partOf = [ "comfyui.service" ];
    # RemainAfterExit: without this, cadvisor logged repeated "no such device"
    # warnings for this unit's cgroup between timer firings (2026-09-06,
    # confirmed in the journal). Keeping it active (exited) keeps the cgroup around.
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${vramGuard}/bin/comfyui-vram-guard watch";
    };
  };

  systemd.timers.comfyui-vram-guard = {
    description = "Periodic VRAM contention check for comfyui";
    partOf = [ "comfyui.service" ];
    timerConfig = {
      OnActiveSec = "30s";
      OnUnitActiveSec = "30s";
    };
  };

  ############################################################################
  # Auto-resume once the GPU is free — lifecycle is independent of
  # comfyui.service (runs continuously; a no-op without the stop-flag).
  ############################################################################
  systemd.services.comfyui-vram-resume = {
    description = "Resume comfyui once GPU VRAM contention has cleared";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${vramResume}/bin/comfyui-vram-resume";
    };
  };

  systemd.timers.comfyui-vram-resume = {
    description = "Periodic check to auto-resume comfyui after a guard stop";
    # ★ Disabled to match comfyui.service's default-off state ★ this timer is
    #   the only path that could restart a stopped ComfyUI automatically, so
    #   it's closed off along with the service (docs/decisions/2026-09-22-comfyui-disabled-by-default.md).
    wantedBy = [ ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "30s";
    };
  };

  ############################################################################
  # Exposure: tailscale0 only (same policy as ollama). A dedicated Serve port
  # would go in modules/reverse-proxy.nix if subpath serving turns out
  # unsupported (same reasoning as n8n).
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

  # Operating notes, model storage layout: docs/services/comfyui.md.
}
