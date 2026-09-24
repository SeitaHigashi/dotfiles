{ config, lib, pkgs, ... }:

##############################################################################
# FTB Evolution (Minecraft modpack server) as a podman container.
#
# Docs: docs/services/minecraft.md (what/why, modpack IDs, heap sizing,
# networking, cgroup weighting, operations, backups, update procedure).
#
# When you change this file, update docs/services/minecraft.md in the same commit.
##############################################################################

let
  m = import ../machine.nix;

  # FTB API modpack ID — see docs/services/minecraft.md for the curl check.
  ftbModpackId = "125";

  # Version ID for the modpack above — see docs/services/minecraft.md for the
  # curl check and where to find newer version IDs.
  ftbModpackVersionId = "100442";

  # Heap given to the server. Must not push (this + machine.nix's
  # arcMaxBytes) past physical RAM, or the OOM killer can take ZFS down too.
  memory = "8G";

  dataDir = "/srv/minecraft";

  port = 25565;

  # LAN-only. podman's published ports go through DNAT + FORWARD, bypassing
  # the NixOS firewall's INPUT chain, so the listen address itself is pinned
  # to the LAN static IP instead. Falls back to all addresses if no static IP
  # (DHCP) is configured. See docs/services/minecraft.md.
  listenAddress =
    if m.staticAddress == null
    then ""
    else "${lib.head (lib.splitString "/" m.staticAddress)}:";
in
{
  ############################################################################
  # podman
  ############################################################################
  virtualisation.podman = {
    enable = true;

    # Expose a `docker` alias for podman.
    # Cannot be combined with virtualisation.docker.enable = true (both claim
    # /run/docker.sock).
    dockerCompat = true;

    # Let containers resolve each other by name. Not required for a single
    # container, but matters if a management sidecar is added later.
    defaultNetwork.settings.dns_enabled = true;
  };

  virtualisation.oci-containers.backend = "podman";

  ############################################################################
  # Data directory
  #   rpool/srv/minecraft (disko/default.nix) is mounted at /srv/minecraft;
  #   ownership is set up here to match the itzg image's default uid/gid 1000.
  ############################################################################
  systemd.tmpfiles.rules = [
    "d ${dataDir}      0750 1000 1000 -"
    "d ${dataDir}/data 0750 1000 1000 -"
  ];

  ############################################################################
  # Container
  ############################################################################
  virtualisation.oci-containers.containers.ftb-evolution = {
    # FTB Evolution needs a modern Minecraft/Java 21 runtime, hence the
    # java21 tag. Pinned rather than `latest` so an image update can't
    # silently change the JRE out from under a running server.
    image = "docker.io/itzg/minecraft-server:java21";

    ports = [ "${listenAddress}${toString port}:25565" ];

    volumes = [ "${dataDir}/data:/data" ];

    environment = {
      # Minecraft EULA agreement — the server won't start without it.
      EULA = "TRUE";

      # Fetch the modpack from the FTB App API.
      # VERSION_ID must stay pinned — see docs/services/minecraft.md for why
      # (Restart=always makes an unpinned version a real desync risk).
      TYPE = "FTBA";
      FTB_MODPACK_ID = ftbModpackId;
      FTB_MODPACK_VERSION_ID = ftbModpackVersionId;

      # Heap. INIT/MAX kept equal to avoid GC pauses from resizing.
      INIT_MEMORY = memory;
      MAX_MEMORY = memory;

      TZ = "Asia/Tokyo";

      # Run the container's process as 1000:1000 (matches tmpfiles ownership above).
      UID = "1000";
      GID = "1000";
    };

    extraOptions = [
      # Give the world time to save fully on stop.
      # The default 10s can SIGKILL mid-chunk-save.
      "--stop-timeout=120"

      # Put this container's cgroup under a dedicated slice rather than machine.slice.
      # Rootful podman moves it to machine.slice/libpod-<id>.scope, not under
      # this systemd unit — see docs/resource-priority.md. Weight is set on
      # minecraft.slice in modules/resource-priority.nix.
      "--cgroup-parent=minecraft.slice"
    ];

    autoStart = true;
  };

  # systemd-side timeouts are already set by the oci-containers module
  # (TimeoutStartSec=0 = unlimited, TimeoutStopSec=120), so the first modpack
  # download won't get killed.

  ############################################################################
  # Firewall
  #
  # Listen address is already LAN-only; also open the host's INPUT chain
  # (some podman network setups still route through it).
  ############################################################################
  networking.firewall.allowedTCPPorts = [ port ];

  # Operations, backups, and the update procedure: docs/services/minecraft.md
}
