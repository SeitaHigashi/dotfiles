{ config, lib, pkgs, ... }:

##############################################################################
# Cross-service CPU/memory priority (cgroup v2), collected in one file.
#
# Docs: docs/resource-priority.md (why one file, the podman cgroup-parent
# quirk, per-service weights/budgets and their measurements).
#
# When you change this file, update docs/resource-priority.md in the same commit.
##############################################################################

let
  # syncoid builds unit names from the commands' names (e.g. escaped into
  # `syncoid-rpool-root`). Read from config instead of hardcoding, so new
  # targets added in replication.nix aren't missed here. Mirrors syncoid's own
  # escapeUnitName (non [a-zA-Z0-9_.\-] -> "-"); not exposed via lib, so
  # duplicated here.
  escapeUnitName = name:
    lib.concatMapStrings (s: if lib.isList s then "-" else s)
      (builtins.split "[^a-zA-Z0-9_.\\-]+" name);

  syncoidUnits = lib.mapAttrs'
    (name: _: lib.nameValuePair "syncoid-${escapeUnitName name}" {
      serviceConfig.CPUWeight = 20;
    })
    config.services.syncoid.commands;
in
{
  systemd.services = syncoidUnits // {
    # tailscaled — above Minecraft. Rationale: docs/resource-priority.md.
    tailscaled.serviceConfig = {
      CPUWeight = 2000;
      MemoryLow = "256M";
    };

    # Minecraft (podman) is configured below via systemd.slices, not here —
    # the container isn't under this unit's cgroup. See docs/resource-priority.md.

    # ollama — lowest priority when enabled. Commented out to match
    # services.ollama.enable = false (modules/ollama.nix); restore together.
    # See docs/decisions/2026-09-21-ollama-serviceconfig-broken-unit.md for
    # why leaving this active with ollama disabled breaks the host, and
    # docs/resource-priority.md for the budget history.
    # ollama.serviceConfig = {
    #   CPUWeight = 20;
    #   MemoryHigh = "12G";
    # };

    # llama.cpp router (modules/llama-cpp.nix) — same lowest priority as
    # ollama. Budget history and current sizing rationale: docs/resource-priority.md.
    llama-cpp.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "20G";
    };

    # Open WebUI is mostly idle except for RAG embedding.
    open-webui.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "4G";
    };

    # n8n — near-idle while waiting, spikes only during workflow runs.
    # Same lowest priority as ollama/Open WebUI so it can't starve Minecraft.
    # MemoryHigh is a soft ceiling: n8n 2.x runs task runners in separate
    # processes, so memory grows with the workflow; capped to avoid pressuring
    # ZFS ARC (16 GiB) and Minecraft's heap (8 GiB).
    n8n.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "2G";
    };

    # ComfyUI — same "only busy while generating" shape as n8n.
    # Budget history: docs/resource-priority.md.
    comfyui-setup.serviceConfig.CPUWeight = 20;
    comfyui.serviceConfig = {
      CPUWeight = 20;
      MemoryHigh = "8G";
    };

    # Monitoring — light, but should keep running especially during an
    # incident, so not pushed too low. cadvisor is the exception: it scans
    # every container periodically and gets heavy, so it's deprioritized.
    #
    # Replication (syncoid) is set to CPUWeight = 20 above (syncoidUnits) —
    # a nightly bulk transfer, delay is harmless.
    #
    # podman-mc-monitor is a container, so it can't be configured here —
    # it's deprioritized via its machine.slice membership below instead.
    cadvisor.serviceConfig.CPUWeight = 20;
  };

  ############################################################################
  # Slices — for podman containers.
  #
  # These sit as top-level siblings in the cgroup tree, not inside
  # system.slice, so they're compared at a different level than the
  # CPUWeight values above: first split at the root among
  #   system.slice : minecraft.slice : machine.slice : user.slice
  # then further split within each by the weights above.
  #
  # system.slice is raised from the default 100 to 1000 so that, with
  # Minecraft at 1000, tailscaled (weight 2000 *within* system.slice) isn't
  # capped out at the root level. Making the two equal gives a simple split
  # under saturation: "half to Minecraft, half to system.slice (tailscaled
  # prioritized within that half)".
  ############################################################################
  systemd.slices = {
    # Dedicated to the Minecraft container (paired with ftb-evolution.nix's
    # --cgroup-parent). MemoryLow rather than MemoryMax for the same reason
    # as elsewhere — a hard cap makes the JVM fail to allocate heap and crash.
    minecraft = {
      description = "Minecraft server container slice";
      sliceConfig = {
        CPUWeight = 1000;
        MemoryLow = "10G";
      };
    };

    # Home for every other container (e.g. podman-mc-monitor) — podman's
    # default parent slice, so anything without an explicit cgroup-parent
    # lands here.
    machine.sliceConfig.CPUWeight = 20;

    # Matches minecraft.slice at the root level, per the comment above.
    system.sliceConfig.CPUWeight = 1000;
  };
}
