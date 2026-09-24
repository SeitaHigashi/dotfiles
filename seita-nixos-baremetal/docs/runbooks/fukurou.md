# fukurou operations

Overview: [services/fukurou.md](../services/fukurou.md).

## Rebuilding after a code change

```sh
cd ~/fukurou && nix develop --command cargo build --release -p fukurou-server -p fukurou-webui
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

## If STT (whisper.cpp) doesn't seem to use the GPU, or uses the wrong one

Confirm with `vulkaninfo --summary` which Vulkan index maps to which card — **this is not
the same numbering as `nvidia-smi`** (see [services/fukurou.md](../services/fukurou.md)
for the current mapping). Set `GGML_VK_VISIBLE_DEVICES` in `modules/fukurou.nix` to match.

## GPU swap

See [runbooks/gpu.md](gpu.md)'s "After swapping GPU hardware" — `fukurou.nix`'s
`GGML_VK_VISIBLE_DEVICES` must be re-measured with `vulkaninfo --summary` independently of
the CUDA-side re-measurement; they are unrelated enumeration systems that happen to
currently agree with each other in reverse of `nvidia-smi`'s order.
