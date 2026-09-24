# FTB Evolution (Minecraft modpack server)

`modules/ftb-evolution.nix` runs the `itzg/minecraft-server` image under rootful
podman, keeping the world and mods on `/srv/minecraft` (rpool, NVMe SSD). The
modpack itself is fetched automatically on first container start from the FTB App
API (`TYPE=FTBA` + `FTB_MODPACK_ID`) — no manual ZIP placement needed.

## Why the data lives on rpool (SSD), not dpool (HDD mirror)

It used to live on dpool. The HDD mirror is SMR, and periodic autosave chunk
writes (`write(2)`) sometimes took over 60 seconds to return, which triggered
Minecraft's `ServerHangWatchdog` and crashed the server — observed 7 times in one
day. Every crash-report thread dump showed the same stack:

```
"Server thread" RUNNABLE
  at sun.nio.ch.UnixFileDispatcherImpl.write0(Native Method)
  ... MinecraftServer.saveAllChunks / tickServer
```

Pure I/O wait, not a mod issue. Since ZFS doesn't go through blk-cgroup (`IOWeight`
is a no-op — see [docs/resource-priority.md](../resource-priority.md)), moving off
the HDD mirror was the only fix available.

The world can't be regenerated, but rpool is a single vdev with no redundancy.
That gap is covered by `modules/replication.nix`'s daily syncoid replication to
`dpool/backup/minecraft`, plus `com.sun:auto-snapshot=true` on `/srv/minecraft`
giving 15-minute local ZFS snapshots. Container state under
`/var/lib/containers` is on rpool too but isn't replicated — images are
re-fetchable, so that's fine.

## Modpack identity

- Modpack ID `125` = FTB Evolution — confirmed via
  `curl https://api.feed-the-beast.com/v1/modpacks/public/modpack/125`
  (`"name": "FTB Evolution"`).
- Version ID `100442` = 1.40.1 (MC 1.21.1 + NeoForge 21.1.243 + Java 21, matching
  the `java21` image tag) — confirmed via
  `curl https://api.feed-the-beast.com/v1/modpacks/public/modpack/125/100442`.
  Newer version IDs are listed under `"versions"` in the modpack-125 response.

`FTB_MODPACK_VERSION_ID` must always be pinned explicitly. The container has
`Restart=always`; leaving it unset means a crash-triggered restart can silently
pull a major modpack update, desyncing players' client-side mods from the server.

## Heap sizing

`INIT_MEMORY`/`MAX_MEMORY` (currently `8G`) are kept equal to avoid GC pauses from
heap resizing. This value plus `machine.nix`'s `arcMaxBytes` (ZFS ARC limit) must
not exceed physical RAM — going over risks the OOM killer taking ZFS down with it.

## Networking

LAN-only by design. Podman's published ports go through DNAT + FORWARD, which
bypasses the NixOS firewall's INPUT chain, so the fix is binding the listen
address itself to the LAN static IP (`modules/ftb-evolution.nix`'s
`listenAddress`) rather than relying on the firewall alone. Falls back to
listening on all addresses if the host has no static IP (DHCP config).

## cgroup weighting

The container's CPU/memory priority is **not** set on the `podman-ftb-evolution`
systemd unit — rootful podman moves the container process to
`machine.slice/libpod-<id>.scope`, not under the unit's own cgroup (measured:
unit `cpu.weight=1000`, container `cpu.weight=100`). Instead
`extraOptions = [ "--cgroup-parent=minecraft.slice" ]` places it under a dedicated
slice, weighted in `modules/resource-priority.nix`. Full explanation:
[docs/resource-priority.md](../resource-priority.md).

## Operations

```sh
systemctl status podman-ftb-evolution        # status
journalctl -u podman-ftb-evolution -f        # logs
podman exec -i ftb-evolution rcon-cli        # console
systemctl stop podman-ftb-evolution          # stop
zfs list -t snapshot -r rpool/srv/minecraft  # local snapshots
zfs list -t snapshot -r dpool/backup/minecraft  # replicated snapshots
```

### Backups

The modpack's bundled FTB Backups 3 is disabled — it produced a 1.5 GB zip every 2
hours, fully redundant with ZFS snapshots and responsible for a large share of
write volume. Setting is `auto: false` in
`data/world/serverconfig/ftbbackups3-server.snbt` (must be under `world/serverconfig/`,
not `config/` — `config/` gets overwritten on every modpack update).

Recovery goes through ZFS:

```sh
zfs list -t snapshot -r rpool/srv/minecraft
zfs rollback rpool/srv/minecraft@<snapshot-name>
```

If the SSD itself is lost, restore by receiving from `dpool/backup/minecraft`.

### Updating the modpack

Change `ftbModpackVersionId` in `modules/ftb-evolution.nix` and
`nixos-rebuild switch`. The world at `/srv/minecraft/data` persists across the
update, but snapshot first:

```sh
zfs snapshot dpool/srv/minecraft@before-update
```

The container image itself is not auto-updated — oci-containers' generated
`ExecStartPre` only does `podman rm -f`, never a pull, so a once-fetched tag stays
put across restarts and rebuilds. To bump it:

```sh
podman pull docker.io/itzg/minecraft-server:java21
systemctl restart podman-ftb-evolution
```
