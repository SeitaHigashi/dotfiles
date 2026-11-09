# fukurou operations

Overview: [services/fukurou.md](../services/fukurou.md).

## Rebuilding after a code change

```sh
cd ~/src/fukurou && nix develop --command cargo build --release -p fukurou-server -p fukurou-webui
sudo systemctl restart fukurou-server fukurou-webui
```

Nix does not build fukurou — this module only launches the already-built
`target/release/` binaries, so a rebuild has to happen manually before restarting.

## If the `claude` CLI subprocess fails

- Check `~/.claude/` auth state is valid for `seita` (the service runs as `seita`
  specifically because of this — see [services/fukurou.md](../services/fukurou.md)).
- Check `journalctl -u fukurou-server` for `command not found` on `claude` or `node`
  — both come from PATH entries added via `systemd.services.fukurou-server.path`
  (`~/.nix-profile` for `claude`, `/etc/profiles/per-user/seita` for `node`, needed by the
  `SessionEnd` hook). If either is missing, check that those directories still exist and
  contain the expected binaries.

## If STT/TTS fail

STT and TTS are lfm3-audio behind llama-swap (see [services/fukurou.md](../services/fukurou.md)).

- `curl -s http://127.0.0.1:8888/running` — lfm3-audio should be listed once a session
  starts (llama-swap loads it on demand; it is mutually exclusive with `laya`/`jeff`, so
  one of those being loaded can evict or block it).
- The realtime URL in `~/src/fukurou/config/server.toml` `[speech]` must be the
  `/upstream/lfm3-audio/v1/realtime` form; plain `/v1/realtime?model=...` does not upgrade
  to a WebSocket on llama-swap.
- `journalctl -u fukurou-server -e` for connect/upgrade errors, and
  `journalctl -u llama-cpp -e` for lfm3-audio load failures (VRAM on the 1660 SUPER).
