# Textfile-collector metrics: manual verification

Covers the four textfile-collector modules documented in
[services/textfile-metrics.md](../services/textfile-metrics.md).

## Run a collector on demand and inspect its output

```bash
# nix-info.nix
sudo systemctl start nixos-package-metrics hydra-build-metrics nixos-package-upstream-metrics
cat /var/lib/prometheus-node-exporter-text-files/nixos-packages.prom
cat /var/lib/prometheus-node-exporter-text-files/hydra-build-status.prom
cat /var/lib/prometheus-node-exporter-text-files/nixos-package-upstream-status.prom

# nix-profile-info.nix
sudo systemctl start nix-profile-metrics nix-profile-upstream-metrics
cat /var/lib/prometheus-node-exporter-text-files/nix-profile-packages.prom
cat /var/lib/prometheus-node-exporter-text-files/nix-profile-upstream-status.prom

# zfs-snapshot-metrics.nix
sudo systemctl start zfs-snapshot-metrics
cat /var/lib/prometheus-node-exporter-text-files/zfs-snapshots.prom

# gpu-xid-metrics.nix
sudo systemctl start gpu-xid-metrics
cat /var/lib/prometheus-node-exporter-text-files/gpu-xid.prom
```

## Confirm node_exporter is actually serving them

```bash
curl -s localhost:9100/metrics | grep -E '^(nixos_installed|nixos_package_upstream|nixos_channel|hydra_)'
curl -s localhost:9100/metrics | grep '^nix_profile_'
curl -s localhost:9100/metrics | grep -E '^zfs_(snapshot|pool)'
curl -s localhost:9100/metrics | grep -E '^gpu_(xid|reboot)'

# textfile collector itself is healthy (0 = no parse errors across all *.prom files)
curl -s localhost:9100/metrics | grep node_textfile_scrape_error
```

## Testing the GPU Xid alert path without a real Xid

Don't feed synthetic Xid log lines into the real journal to test alerting — prefer
temporarily changing the relevant rule in `modules/alerting.nix` to `vector(1)`,
switching once to confirm the notification fires, then reverting.
