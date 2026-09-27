{ config, lib, pkgs, ... }:

##############################################################################
# Grafana alerting (Unified Alerting).
#
# Docs:
#   - docs/services/alerting.md    conventions, mkRule, MetricsQL pitfalls, n8n
#   - docs/runbooks/alerting.md    add/change/delete a rule, test the notify path
#   - docs/decisions/2026-08-25-alerting-split-from-monitoring.md
#   - docs/decisions/2026-08-25-mkrule-instant-query-shape.md
#
# When you change this file, update the docs above in the same commit.
##############################################################################

let
  # Disk by-id paths are host-specific, so pull them from machine.nix.
  m = import ../machine.nix;

  # Data source uid, fixed in modules/monitoring.nix's provision.datasources.
  # Changing it turns every rule into a "datasource not found" Error.
  dsUid = "victoriametrics";

  n8nPort = 5678;  # must match modules/n8n.nix's port

  folder = "alerts";  # Grafana creates this folder automatically during provisioning

  # Builds one alert rule. See docs/services/alerting.md#rule-conventions for the
  # full rationale (always-emitting instant query + threshold, uid, noData).
  mkRule =
    { uid
    , title
    , expr
    , op
    , limit
    , pending
    , severity
    , summary
    , description
    , noData ? "OK"
    }:
    {
      inherit uid title;
      condition = "B";
      for = pending;
      isPaused = false;
      noDataState = noData;
      # Keep Error: a broken query is itself worth being notified about.
      execErrState = "Error";

      data = [
        {
          refId = "A";
          # The window is unused for an instant query,
          # but Grafana requires the field.
          relativeTimeRange = { from = 600; to = 0; };
          datasourceUid = dsUid;
          model = {
            refId = "A";
            datasource = { type = "prometheus"; uid = dsUid; };
            editorMode = "code";
            inherit expr;
            instant = true;
            range = false;
          };
        }
        {
          refId = "B";
          relativeTimeRange = { from = 600; to = 0; };
          datasourceUid = "__expr__";  # Grafana's internal pseudo-datasource for expression nodes
          model = {
            refId = "B";
            datasource = { type = "__expr__"; uid = "__expr__"; };
            type = "threshold";
            expression = "A";
            conditions = [
              {
                type = "query";
                evaluator = { type = op; params = [ limit ]; };
                operator.type = "and";
                query.params = [ "A" ];
                reducer = { type = "last"; params = [ ]; };  # A is instant, already 1 point; reducer is a formality
              }
            ];
          };
        }
      ];

      labels = { inherit severity; };
      annotations = { inherit summary description; };
    };

  # SMART labels are the disk's by-id name (path stripped). Keeps machine.nix as
  # the single source for disk names rather than hardcoding them here.
  deviceOf = path: baseNameOf path;
in
{
  services.grafana.provision.alerting = {

    # Contact points
    contactPoints.settings = {
      apiVersion = 1;
      contactPoints = [
        {
          orgId = 1;
          name = "n8n-webhook";
          receivers = [
            {
              uid = "n8n-webhook";
              type = "webhook";
              settings = {
                # Path matches the n8n workflow "Notify Grafana Alert to Discord"
                # (fD6js4TzcXdUF4Wx)'s Webhook node. The trailing random suffix is
                # n8n's own and can't be shortened without editing that workflow
                # (any other path 404s).
                url = "http://127.0.0.1:${toString n8nPort}/webhook/grafana-alert-40b2fc68";
                httpMethod = "POST";
              };
              disableResolveMessage = false;  # send resolved notices too, or firing state becomes unknowable
            }
          ];
        }
      ];
    };

    # Notification policy: this is a home server, so re-notification is kept
    # infrequent (12h) rather than paging repeatedly for the same issue.
    # Severity-based routing is done in n8n, not here (tunable without touching Nix).
    policies.settings = {
      apiVersion = 1;
      policies = [
        {
          orgId = 1;
          receiver = "n8n-webhook";
          group_by = [ "alertname" "grafana_folder" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "12h";
        }
      ];
    };

    # Rules. To delete one, removing it from `groups` alone is not enough — see
    # docs/runbooks/alerting.md#delete-a-rule for the deleteRules procedure.
    rules.settings = {
      apiVersion = 1;

      groups = [

        # Infra
        {
          orgId = 1;
          name = "infra";
          inherit folder;
          interval = "1m";
          rules = [

            (mkRule {
              uid = "zfs-pool-degraded";
              title = "ZFS pool is not ONLINE";
              # From modules/zfs-snapshot-metrics.nix; node_exporter's zfs
              # collector does not expose pool health.
              expr = "max by (pool) (zfs_pool_health)";
              op = "gt";
              limit = 0;
              pending = "5m";
              severity = "critical";
              summary = "ZFS pool {{ $labels.pool }} is not ONLINE";
              description = "Check zpool status. For dpool this means one side of the mirror is down; for rpool there is no redundancy at all, so this needs immediate attention.";
            })

            (mkRule {
              uid = "filesystem-space-low";
              title = "Filesystem free space is low";
              # ZFS datasets share their pool's free space, so alerting on every
              # mountpoint would fire dozens of times for one event. Watch one
              # representative mountpoint per pool (/ = rpool, /srv = dpool);
              # /boot is a separate vfat filesystem, included on its own.
              expr = ''min by (mountpoint) (node_filesystem_avail_bytes{mountpoint=~"/|/srv|/boot"} / node_filesystem_size_bytes)'';
              op = "lt";
              limit = 0.10;
              pending = "15m";
              severity = "warning";
              summary = "{{ $labels.mountpoint }} free space has dropped below 10%";
              description = "When ZFS runs out of space, deleting things becomes hard as well as writing. Consider pruning snapshots.";
            })

            (mkRule {
              uid = "smart-status-failed";
              title = "SMART overall health is FAILED";
              # 1 = passed. This means the disk itself reports being past saving.
              expr = "min by (device) (smartctl_device_smart_status)";
              op = "lt";
              limit = 1;
              pending = "10m";
              severity = "critical";
              summary = "{{ $labels.device }}'s SMART status is FAILED";
              description = "Treat this as a disk to be replaced. If it's the rpool side (SSD), first check that the backup to dpool is up to date.";
            })

            (mkRule {
              uid = "nvme-wearout";
              title = "NVMe wear is advancing";
              # NVMe-only metric; HDDs do not expose it.
              expr = "max by (device) (smartctl_device_percentage_used)";
              op = "gt";
              limit = 80;
              pending = "1h";
              severity = "warning";
              summary = "{{ $labels.device }}'s write endurance has exceeded 80%";
              description = "Less than 20% life remains. Plan a replacement.";
            })

            (mkRule {
              uid = "nvme-critical-warning";
              title = "NVMe is raising a critical warning";
              expr = "max by (device) (smartctl_device_critical_warning)";
              op = "gt";
              limit = 0;
              pending = "10m";
              severity = "critical";
              summary = "{{ $labels.device }} is reporting a critical warning";
              description = "Could be temperature, spare blocks, read-only mode, or similar. Check the details with smartctl -a.";
            })

            (mkRule {
              uid = "hdd-temperature-high";
              title = "HDD temperature is high";
              # HDD lifespan visibly shortens above 55C. NVMe normally runs
              # around 50C, hence a separate rule for it.
              expr = ''max by (device) (smartctl_device_temperature{temperature_type="current",device=~"${deviceOf m.hdd1}|${deviceOf m.hdd2}"})'';
              op = "gt";
              limit = 55;
              pending = "30m";
              severity = "warning";
              summary = "HDD {{ $labels.device }} has exceeded 55°C";
              description = "Check the case airflow.";
            })

            (mkRule {
              uid = "nvme-temperature-high";
              title = "NVMe temperature is high";
              # Normal operating temp is ~50C, so 75C catches it just before
              # thermal throttling would start.
              expr = ''max by (device) (smartctl_device_temperature{temperature_type="current",device="${deviceOf m.ssd}"})'';
              op = "gt";
              limit = 75;
              pending = "15m";
              severity = "warning";
              summary = "NVMe {{ $labels.device }} has exceeded 75°C";
              description = "Throttling will degrade I/O. Check the heatsink and airflow.";
            })

            (mkRule {
              uid = "memory-low";
              title = "Memory free space is low";
              # ZFS ARC is not counted in MemAvailable (it's "used" even though
              # reclaimable), so this also fires if arcMaxBytes is set too high.
              expr = "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes";
              op = "lt";
              limit = 0.10;
              pending = "15m";
              severity = "warning";
              summary = "Available memory has dropped below 10%";
              description = "Review the total of Minecraft's heap, ollama's model, and the ARC limit -- before the OOM killer runs.";
            })

            (mkRule {
              uid = "cpu-saturated";
              title = "CPU is saturated";
              expr = ''1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))'';
              op = "gt";
              limit = 0.90;
              pending = "30m";
              severity = "warning";
              summary = "CPU usage has exceeded 90% for over 30 minutes";
              description = "Normal during LLM inference or a build. If nothing comes to mind, look for a runaway process.";
            })

            (mkRule {
              uid = "gpu-reboot-required";
              title = "GPU is raising a fatal Xid error (reboot required)";
              # Metric from modules/gpu-xid-metrics.nix. Added after a 2026-08-28
              # incident: GPU1 dropped with "fallen off the bus" (Xid 79), ollama
              # fell back to CPU, and OpenViking's summary task failed entirely.
              # nvidia-gpu-exporter does not expose Xid (see README.md), so this
              # metric is the only detection path.
              expr = "max by (pci) (gpu_reboot_required)";
              op = "gt";
              limit = 0;
              # State-based metric (not a counter); as soon as it appears it's
              # already fatal, so keep pending as short as possible.
              pending = "1m";
              severity = "critical";
              summary = "GPU {{ $labels.pci }} is raising a fatal Xid error";
              description = "Check the details with journalctl -k -g 'NVRM: Xid' and confirm whether a reboot recovers it (e.g. Xid 79 = fallen off the bus). Also check whether ollama has fallen back to CPU via the PROCESSOR column of `ollama ps`.";
            })

            (mkRule {
              uid = "gpu-xid-metrics-stale";
              title = "GPU Xid metrics collection has stopped";
              # The timer runs every 2 minutes, so treat 15 minutes as stale.
              expr = "time() - gpu_xid_metrics_last_run_seconds";
              op = "gt";
              limit = 900;
              pending = "10m";
              severity = "warning";
              noData = "Alerting";
              summary = "gpu-xid-metrics output has not updated for over 15 minutes";
              description = "The gpu-reboot-required rule above can no longer be trusted. Check systemctl status gpu-xid-metrics.timer.";
            })

            (mkRule {
              uid = "systemd-unit-failed";
              title = "systemd unit is failed";
              # Catch-all for any unit; individual service liveness is the
              # "services" group below.
              expr = ''sum by (name) (node_systemd_unit_state{state="failed"})'';
              op = "gt";
              limit = 0;
              pending = "5m";
              severity = "warning";
              summary = "{{ $labels.name }} is in a failed state";
              description = "Check journalctl -u {{ $labels.name }}.";
            })
          ];
        }

        ######################################################################
        # Service liveness
        ######################################################################
        {
          orgId = 1;
          name = "services";
          inherit folder;
          interval = "1m";
          rules = [

            (mkRule {
              uid = "scrape-target-down";
              title = "Scrape target is down";
              # If an exporter dies, every alert downstream of it goes silent too.
              # This catches "monitoring itself has gone blind" as critical.
              expr = "min by (job, instance) (up)";
              op = "lt";
              limit = 1;
              pending = "5m";
              severity = "critical";
              summary = "Cannot scrape {{ $labels.job }} ({{ $labels.instance }})";
              description = "Every metric this exporter is responsible for is currently missing.";
            })

            (mkRule {
              uid = "service-inactive";
              title = "A resident service is down";
              # All are Restart-always resident units, so "not active" can safely
              # be read as "down".
              #
              # **Only include a unit here if it is meant to be always running.**
              # A manually-started (wantedBy = []) unit still exists in
              # /etc/systemd/system and node_exporter keeps reporting it inactive,
              # which would turn into a permanently-firing alert that buries real
              # ones. `llama-cpp.service` went through exactly this: excluded
              # while it was manual-start, added on 2026-09-23 once it became
              # wantedBy = [ "multi-user.target" ] (and `ollama.service` was
              # removed on 2026-09-21 once `services.ollama.enable = false` made
              # it permanently inactive). Verified current as of 2026-09-24
              # (`systemctl is-enabled llama-cpp.service` → enabled/active;
              # `ollama.service` → not-found). Full history:
              # docs/decisions/2026-09-23-ollama-to-llama-cpp.md (owned by the
              # llama-cpp module docs). If llama-cpp ever goes back to manual
              # start, remove it from this expression again.
              expr = ''min by (name) (node_systemd_unit_state{state="active",name=~"grafana.service|victoriametrics.service|n8n.service|open-webui.service|llama-cpp.service|tailscaled.service|podman-ftb-evolution.service|podman-mc-monitor.service"})'';
              op = "lt";
              limit = 1;
              pending = "10m";
              severity = "critical";
              summary = "{{ $labels.name }} is not active";
              description = "Check systemctl status {{ $labels.name }}.";
            })

            (mkRule {
              uid = "minecraft-unhealthy";
              title = "Minecraft server is not responding";
              # A running container can still hang on world load, so this is
              # kept separate from the process-level check (service-inactive above).
              expr = "min(minecraft_status_healthy)";
              op = "lt";
              limit = 1;
              pending = "10m";
              severity = "warning";
              summary = "Minecraft server is not responding to status pings";
              description = "Right after a modpack update this may just be waiting to start up. Check podman logs ftb-evolution.";
            })
          ];
        }

        # Backup (replication and snapshots). rpool is a single vdev with no
        # redundancy, so replication to dpool is the only safety net. Not
        # noticing it has stopped is the worst outcome, so unit failure and
        # actual data staleness are watched separately — a unit can exit
        # successfully while transferring nothing (see README.md's replication
        # section).
        {
          orgId = 1;
          name = "backup";
          inherit folder;
          interval = "5m";
          rules = [

            (mkRule {
              uid = "replication-lag";
              title = "Replication is lagging";
              # Daily replication, so 24h + 12h grace = 36h (129600 seconds).
              expr = ''max by (dataset) (time() - zfs_snapshot_latest_creation_seconds{dataset=~"dpool/backup/.*"})'';
              op = "gt";
              limit = 129600;
              pending = "30m";
              severity = "critical";
              noData = "Alerting";  # the series disappearing IS the failure (dataset lost entirely)
              summary = "{{ $labels.dataset }}'s latest backup is more than 36 hours old";
              description = "Either syncoid has stopped, or the source side has no snapshots. If the SSD died right now, this much data would be lost.";
            })

            (mkRule {
              uid = "syncoid-failed";
              title = "syncoid has failed";
              # `[.]` instead of `\.`: MetricsQL parses the backslash as a string
              # escape inside double quotes before it reaches the regex, causing
              # a syntax error (confirmed on hardware). See docs/services/alerting.md.
              expr = ''sum by (name) (node_systemd_unit_state{state="failed",name=~"syncoid-.*[.]service"})'';
              op = "gt";
              limit = 0;
              pending = "5m";
              severity = "critical";
              summary = "{{ $labels.name }} failed";
              description = "Check journalctl -u {{ $labels.name }}.";
            })

            (mkRule {
              uid = "zfs-snapshot-metrics-stale";
              title = "ZFS metrics collection has stopped";
              # If this is stale, the replication-lag rule above can no longer be
              # trusted. The timer runs every 5 minutes, so treat 30 minutes as stale.
              expr = "time() - zfs_snapshot_metrics_last_run_seconds";
              op = "gt";
              limit = 1800;
              pending = "10m";
              severity = "warning";
              noData = "Alerting";
              summary = "zfs-snapshot-metrics output has not updated for over 30 minutes";
              description = "The replication-lag and snapshot-count metrics are now stale. Check systemctl status zfs-snapshot-metrics.timer.";
            })
          ];
        }
      ];
    };
  };

  # Verifying the alert path: see docs/services/alerting.md#verifying-the-alert-path.
}
