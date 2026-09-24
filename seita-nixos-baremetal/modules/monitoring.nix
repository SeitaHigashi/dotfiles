{ config, lib, pkgs, ... }:

##############################################################################
# Monitoring stack (VictoriaMetrics + Loki + Grafana).
#
# Docs:
#   - docs/services/monitoring.md    what/how, ports, exporters, dashboards, MCP
#   - docs/runbooks/monitoring.md    editing a dashboard, adding an exporter
#   - docs/decisions/2026-08-25-victoriametrics-over-prometheus.md
#   - docs/decisions/2026-08-25-community-dashboard-panel-cuts.md
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  m = import ../machine.nix;

  ports = {
    victoriametrics = 8428;
    loki            = 3100;
    promtail        = 9080;   # own health/metrics; default 80 fails to bind unprivileged
    grafana         = 3000;
    node            = 9100;
    smartctl        = 9633;
    nvidia          = 9835;
    cadvisor        = 8081;   # 8080 avoided: likely to collide with a future web app
    minecraft       = 9150;
    n8n             = 5678;   # paired with modules/n8n.nix; Web UI and /metrics share it
  };

  # Grafana admin password file. No secret store (sops-nix/agenix) in this repo yet,
  # so the value is kept out of the nix store/git via Grafana's own $__file{}
  # expansion. First-time setup and the "permission denied" gotcha are in
  # docs/services/monitoring.md.
  grafanaPasswordFile = "/var/lib/grafana/admin-password";

  # SMART devices, from machine.nix's by-id paths (sda/sdb numbering isn't stable
  # across boots).
  smartDevices = [ m.ssd m.hdd1 m.hdd2 ];

  # Minecraft listen address; same derivation as modules/ftb-evolution.nix
  # (LAN IP if a static IP is configured).
  minecraftHost =
    if m.staticAddress == null
    then "127.0.0.1"
    else lib.head (lib.splitString "/" m.staticAddress);
in
{
  # Metrics storage is a dedicated ZFS dataset (disko/default.nix,
  # rpool/var/lib/private/victoriametrics, recordsize=16K, auto-snapshot=false,
  # excluded from syncoid replication). See docs/services/monitoring.md#storage.
  services.victoriametrics = {
    enable = true;

    listenAddress = "127.0.0.1:${toString ports.victoriametrics}";

    # ~6 months. Must be given in days: VictoriaMetrics rejects "6m" as ambiguous
    # between months and minutes.
    retentionPeriod = "180d";

    # 30s, not 15s: prioritizes not stealing CPU from the Minecraft tick on this
    # 4C/8T host. See docs/services/monitoring.md.
    prometheusConfig = {
      global.scrape_interval = "30s";

      scrape_configs = [
        {
          job_name = "node";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.node}" ]; }];
        }
        {
          job_name = "smartctl";
          # SMART values only move on a minute scale; scraping more often just
          # risks waking the disk for no benefit.
          scrape_interval = "5m";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.smartctl}" ]; }];
        }
        {
          job_name = "nvidia";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.nvidia}" ]; }];
        }
        {
          job_name = "cadvisor";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.cadvisor}" ]; }];
        }
        {
          job_name = "minecraft";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.minecraft}" ]; }];
        }

        {
          # Assumes N8N_METRICS=true in modules/n8n.nix (2.x only reads this from
          # an env var, not the settings JSON). Same port as the Web UI, /metrics.
          job_name = "n8n";
          static_configs = [{ targets = [ "127.0.0.1:${toString ports.n8n}" ]; }];
        }

        # To add later, if a service starts emitting Prometheus metrics:
        #
        # {
        #   job_name = "ollama";
        #   # Ollama itself does not emit Prometheus-format metrics. GPU side is
        #   # covered by the nvidia job above, process side by cadvisor / node's
        #   # processes collector.
        # }
        #
        # (Ollama is currently disabled — modules/ollama.nix — in favour of
        # llama.cpp; this placeholder predates that and is kept only as an example
        # of the shape a metrics-less-service entry would take.)
      ];
    };
  };

  # Logs (Loki + Promtail): whole-journald collection, 127.0.0.1-only, read only
  # from Grafana. See docs/services/monitoring.md for why journald alone covers
  # both systemd services and podman containers.
  #
  # loki runs as a fixed user, not DynamicUser, so it needs an explicit chown of
  # its ZFS-backed data dir every boot (see docs/services/monitoring.md#storage).
  systemd.tmpfiles.rules = [
    "d /var/lib/loki 0700 loki loki - -"
  ];

  services.loki = {
    enable = true;

    # Single binary, single instance, filesystem storage (TSDB index + chunks on
    # local disk) — plenty for this host's scale.
    configuration = {
      auth_enabled = false;

      server = {
        http_listen_address = "127.0.0.1";
        http_listen_port = ports.loki;
      };

      common = {
        path_prefix = config.services.loki.dataDir;
        storage.filesystem = {
          chunks_directory = "${config.services.loki.dataDir}/chunks";
          rules_directory = "${config.services.loki.dataDir}/rules";
        };
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
        # Pinned to loopback: left unset, Loki registers the default-route NIC
        # address (this host's LAN static IP) as its ring self-address and dials
        # its own gRPC (9095) over the LAN, which fails hard on any LAN blip
        # (docs/services/monitoring.md).
        instance_addr = "127.0.0.1";
      };

      schema_config.configs = [
        {
          from = "2026-01-01";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index = {
            prefix = "index_";
            period = "24h";
          };
        }
      ];

      # 14-day retention; the SSD rpool has plenty of headroom and this is enough
      # lookback for incident triage.
      compactor = {
        working_directory = "${config.services.loki.dataDir}/compactor";
        retention_enabled = true;
        delete_request_store = "filesystem";
      };
      limits_config = {
        retention_period = "336h"; # 14d
      };
    };
  };

  services.promtail = {
    enable = true;

    configuration = {
      # Own health/metrics listener, 127.0.0.1 only like the other exporters
      # (default is 0.0.0.0). Port must be explicit — the default is 80, which the
      # unprivileged promtail user cannot bind (confirmed on hardware).
      server.http_listen_address = "127.0.0.1";
      server.http_listen_port = ports.promtail;
      server.grpc_listen_address = "127.0.0.1";
      server.grpc_listen_port = ports.promtail + 1;

      positions.filename = "/var/cache/promtail/positions.yaml";

      clients = [
        { url = "http://127.0.0.1:${toString ports.loki}/loki/api/v1/push"; }
      ];

      scrape_configs = [
        {
          job_name = "journal";
          journal = {
            path = "/var/log/journal";
            max_age = "12h";
            labels.job = "journal";
          };
          # Promote the unit name to a label. Minecraft shows up as
          # "podman-ftb-evolution.service", so LogQL can filter with
          # {unit=~"podman-.+"}.
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
          ];
        }
      ];
    };
  };

  # exporters: all 127.0.0.1-only, same as VictoriaMetrics itself, so nothing here
  # is reachable from outside this host.
  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.node;

    # Extra collectors beyond the defaults: zfs, systemd, processes.
    # See docs/services/monitoring.md for what each is used for.
    enabledCollectors = [ "zfs" "systemd" "processes" ];

    # textfile collector directory (enabled by default, but reads nothing unless
    # a directory is given). Written by modules/zfs-snapshot-metrics.nix's timer
    # every 5 minutes; path must match that module's textfileDir.
    extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files" ];
  };

  services.prometheus.exporters.smartctl = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.smartctl;
    devices = smartDevices;

    # Shorter than the 5m scrape interval, so scrapes don't just re-read a stale
    # cached value.
    maxInterval = "2m";
  };

  # NVIDIA GPU exporter: utkuozdemir's (parses nvidia-smi), not the
  # nixpkgs services.prometheus.exporters.nvidia-gpu module (mindprince's,
  # NVML-based, unmaintained). Run as a plain systemd unit. See
  # docs/services/monitoring.md for why (per-GPU uuid/name labels) and its limits.
  systemd.services.nvidia-gpu-exporter = {
    description = "NVIDIA GPU Prometheus exporter";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    # nvidia-smi ships in nvidia_x11.bin and must match the loaded driver version,
    # hence pulling it from config rather than nixpkgs directly.
    path = [ config.hardware.nvidia.package.bin ];

    serviceConfig = {
      ExecStart = ''
        ${pkgs.prometheus-nvidia-gpu-exporter}/bin/nvidia_gpu_exporter \
          --web.listen-address=127.0.0.1:${toString ports.nvidia}
      '';
      Restart = "always";
      RestartSec = "10s";

      DynamicUser = true;
      SupplementaryGroups = [ "video" ];  # needed to access the GPU device files

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # cadvisor: per-podman-container CPU/mem/IO (Minecraft today, a future n8n
  # container). See docs/services/monitoring.md for the container-naming limit.
  services.cadvisor = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = ports.cadvisor;
  };

  # Minecraft health: itzg/mc-monitor server-list-ping (25565), no RCON.
  # No TPS — see docs/services/monitoring.md for why.
  virtualisation.oci-containers.containers.mc-monitor = {
    image = "docker.io/itzg/mc-monitor:latest";

    # mc-monitor uses Go's stdlib flag package: single-dash flags only. A
    # GNU-style "--bind" is rejected (exit code 2).
    cmd = [
      "export-for-prometheus"
      "-servers" "${minecraftHost}:25565"
      "-port" (toString ports.minecraft)
    ];

    ports = [ "127.0.0.1:${toString ports.minecraft}:${toString ports.minecraft}" ];

    autoStart = true;
  };

  # Start only after Minecraft itself is up. Starting earlier wouldn't break
  # anything (pings just fail until Minecraft answers), but clutters the log.
  systemd.services.podman-mc-monitor = {
    after = [ "podman-ftb-evolution.service" ];
    wants = [ "podman-ftb-evolution.service" ];
  };

  # Grafana listens on 0.0.0.0, but the firewall only opens the tailscale0
  # interface, so it's reachable only from the tailnet. Filtering by interface
  # rather than http_addr because the Tailscale IP isn't known at build time.
  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = ports.grafana;
        domain = m.hostName;  # only used to build relative URLs; hostname is enough
      };

      security = {
        admin_user = "admin";
        # $__file{} is Grafana's own file-expansion; keeps the password out of the
        # nix store and git. See docs/services/monitoring.md for first-time setup.
        admin_password = "$__file{${grafanaPasswordFile}}";
      };

      # Anonymous access and sign-up left disabled: even inside the tailnet, a
      # borrowed device shouldn't get free access.
      "auth.anonymous".enabled = false;
      users.allow_sign_up = false;

      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
      };
    };

    provision = {
      enable = true;

      datasources.settings.datasources = [
        {
          # VictoriaMetrics speaks the Prometheus-compatible API, so type
          # "prometheus" works unchanged.
          name = "VictoriaMetrics";
          type = "prometheus";
          access = "proxy";

          # Pinned uid: every dashboards/*.json references the data source by
          # this uid. Changing it breaks every dashboard with "No data".
          uid = "victoriametrics";

          url = "http://127.0.0.1:${toString ports.victoriametrics}";
          isDefault = true;
          jsonData = {
            timeInterval = "30s";  # matches the scrape interval; keeps graph interpolation sane
          };
        }
        {
          name = "Loki";
          type = "loki";
          access = "proxy";
          uid = "loki";
          url = "http://127.0.0.1:${toString ports.loki}";
          isDefault = false;
        }
      ];

      # Dashboards: the whole repo dashboards/ directory, read-only from the UI
      # (allowUiUpdates = false; git is the single source of truth). Inventory,
      # edit procedure, and per-dashboard panel cuts are in
      # docs/services/monitoring.md and docs/runbooks/monitoring.md.
      dashboards.settings.providers = [
        {
          name = "nixos";
          options.path = ../dashboards;

          allowUiUpdates = false;
          disableDeletion = true;
        }
      ];
    };
  };

  # Firewall: no port opened here for Grafana. Reachability goes exclusively
  # through modules/reverse-proxy.nix's Tailscale Serve (tailnet 443); Grafana's
  # own 3000 is not directly reachable even from the tailnet, and not on the LAN.
  # http_addr stays "0.0.0.0" — harmless, since tailscaled terminates 443 and
  # connects to 127.0.0.1:3000 locally. Direct access (e.g. to isolate a
  # reverse-proxy issue): `ssh -L 3000:127.0.0.1:3000 seita-nixos-baremetal`.

  # Operational checks: see docs/services/monitoring.md#operational-checks.
}
