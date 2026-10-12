# Notify (`host-notify`)

One generic notification channel for host jobs, in `modules/notify.nix`: a CLI that POSTs to the n8n webhook
`http://127.0.0.1:5678/webhook/notify`, where the workflow "Host notify to Discord" posts to Discord.
Grafana alerts keep their own path ([alerting.md](alerting.md)); their payload is Grafana's.

## Usage

```bash
echo "last log lines" | host-notify SOURCE LEVEL TITLE [MESSAGE]   # stdin is optional
host-notify my-backup info "backup done" "rpool/var/lib, 12 GiB"
```

In a Nix module add `config.local.notify.package` to the script's `runtimeInputs` and call `host-notify`.
It always exits 0 (a notification must never fail its caller), has a 10 s timeout, and sends the last
8000 bytes of stdin as `log`.

## Payload

```json
{ "source": "nix-auto-update", "level": "debug|info|warning|error",
  "title": "...", "message": "...", "log": "..." }
```

**The sender decides the level; n8n only renders.** `debug` is dropped (the n8n execution still shows up
as a heartbeat), the others are coloured by level; an unknown level is treated as `info`. Pick `debug` for
"ran, nothing to say" and `warning`/`error` for things a human should look at.

## Clients

| source | Where | Doc |
|---|---|---|
| `nix-auto-update`, `podman-auto-update` | `modules/auto-update.nix` | [auto-update.md](auto-update.md) |
| `host-boot` | `modules/notify.nix` (`host-boot-notify.service`) | below |
| `zed` | `modules/zfs.nix` (`services.zfs.zed.settings`) | below |
| `systemd` | `modules/notify.nix` (`notify-failure@.service`) | below |

### host-boot — boot report
Sent once per boot after n8n answers `/healthz` (waits up to 2 min). `ExecStop` drops
`/var/lib/host-boot/clean` at shutdown; a boot that finds no marker reports `warning` "booted after a
crash" with the tail of the previous boot's journal, otherwise `info` "booted". The **first boot after
this unit is deployed has no marker and reports one false crash**. This exists because Grafana and n8n
die with the host, so a crash is otherwise only visible in `last -x`.

### zed — ZFS events
ZED's stock zedlets (scrub_finish with errors, statechange, data errors, resilver_finish) pipe their
report into `ZED_EMAIL_PROG`, which is set to `host-notify` with `ZED_EMAIL_OPTS="zed warning '@SUBJECT@'"`.
`ZED_NOTIFY_VERBOSE` is off (a clean scrub is silent) and ZED's 1 h `ZED_NOTIFY_INTERVAL_SECS` rate
limit applies. `services.zfs.zed.enableMail` must stay `false`: it would overwrite `ZED_EMAIL_PROG`.
This catches repaired checksum/IO errors, which leave the pool ONLINE and so never fire the Grafana
`zfs-pool-degraded` rule.

### systemd — OnFailure log tail
A top-level `service.d/10-notify-failure.conf` sets `OnFailure=notify-failure@%n.service` on every
service; the template sends `warning` "<unit> failed" with the last 40 journal lines. The template's own
drop-in clears `OnFailure=` so a failing notifier cannot loop. It **duplicates** Grafana's
`systemd-unit-failed` (kept: this adds the log, that one covers a dead n8n) and the auto-update
units' own report.

n8n side: workflow "Host notify to Discord" (`oeTiIKv3VFCeKOCp`), webhook path `notify`, same Discord
credential as the Grafana notifier. `debug` is dropped; the embed footer shows the level, colours are
green/orange/red, `message` is capped at 1000 chars, `log` is tailed to 2800. The earlier single-purpose
workflow `NF5xPBOgNTUIru6i` (path `auto-update`) is kept but unpublished and renamed "(deprecated)"; re-publish
it only if the old `source: nix|podman` payload is ever needed again.
