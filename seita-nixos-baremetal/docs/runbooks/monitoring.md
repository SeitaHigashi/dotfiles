# Monitoring runbook

Service overview: [services/monitoring.md](../services/monitoring.md).

## Edit a dashboard

Dashboards are provisioned read-only (`allowUiUpdates = false`); the JSON files
under `dashboards/` are the source of truth.

1. In the Grafana UI, open the dashboard and "Save as..." to create an editable copy.
2. Iterate on the copy until it looks right.
3. Export → "Export for sharing externally" **off** → copy the resulting JSON.
4. Overwrite the corresponding file in `dashboards/` with it.
5. `nixos-rebuild switch`.
6. Delete the temporary copy from the UI (it isn't tracked in git and would drift).

If the dashboard came from Grafana.com and still has `__inputs`/`__requires` keys,
strip them — a provisioned dashboard with those keys refuses to render and asks to
be "imported" instead.

## Add a new exporter/scrape target

1. Add the port to the `ports` attrset in `modules/monitoring.nix`.
2. Add the exporter service (or a scrape-only `scrape_configs` entry if it already
   runs elsewhere).
3. Add a `scrape_configs` entry pointing at `127.0.0.1:<port>` (all exporters here
   are loopback-only; do not expose a new one to the LAN or tailnet without a
   reason).
4. `nixos-rebuild switch`, then confirm with:
   ```sh
   curl -s 'localhost:8428/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.job=="<job>")'
   ```

## Recover a broken Loki/Grafana dataset (permission errors)

If `journalctl -u loki` shows `mkdir ...: permission denied`, the ZFS mountpoint was
(re)created with the default `root:root 0755` owner. `systemd.tmpfiles.rules` in
`modules/monitoring.nix` re-chowns `/var/lib/loki` on every boot, so this should
self-heal after a restart; if not, `systemctl restart loki` after confirming the
mountpoint exists.
