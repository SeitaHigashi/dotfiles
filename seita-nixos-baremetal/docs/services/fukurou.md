# fukurou

Implementation: [`modules/fukurou.nix`](../../modules/fukurou.nix)

## What it is

fukurou is a self-developed Rust voice-conversation loop app (`~/src/fukurou`, developed on
this host). `fukurou-server` runs STT → LLM (`claude` CLI) → TTS. Since 2026-11-08 STT and TTS are
both lfm3-audio, reached over a realtime WebSocket through llama-swap
(`ws://127.0.0.1:8888/upstream/lfm3-audio/v1/realtime`, set in `config/server.toml`
`[speech]`); whisper.cpp and VOICEVOX were removed. `fukurou-webui` is a push-to-talk browser test page for it (a development test page
per its README, not a finished GUI). Both were previously started manually in the
foreground by hand; this module makes them always-on systemd services reachable from the
tailnet.

- `fukurou-server`: WebSocket, port 7878. Listens on `0.0.0.0`, tailnet-only via firewall
  (same pattern as ollama), so non-browser clients can connect directly at
  `ws://<tailscale-ip-or-magicdns>:7878`. Also double-published as `wss://` on port 9447
  via `modules/reverse-proxy.nix`, because `fukurou-webui` is served over `https://` and
  browsers block a plain `ws://` connection from an https page as mixed content (confirmed
  2026-08-30). `webui/index.html` defaults to the `wss://` route when loaded over https;
  the plain `ws://:7878` path remains for non-browser clients.
- `fukurou-webui`: HTTP, `127.0.0.1:8765` only (no firewall opening needed). Reached from
  the tailnet only via `modules/reverse-proxy.nix`'s routes — a plain HTTP page, so it
  follows the Open WebUI/Grafana pattern rather than ollama's "0.0.0.0 + firewall" pattern.

## Build

Not packaged in nixpkgs. `~/src/fukurou` (a working checkout on this host) is used directly as
`WorkingDirectory`, and the systemd unit's `ExecStart` runs the already-built
`target/release/` binary — the same "Nix only manages process lifecycle" pattern as
`modules/comfyui.nix`'s pip venv. Rebuild manually:

```sh
cd ~/src/fukurou && nix develop --command cargo build --release -p fukurou-server -p fukurou-webui
sudo systemctl restart fukurou-server fukurou-webui
```

## Why `User = seita`, not `DynamicUser`

The `[claude]` section (`config/server.toml`) shells out to the `claude` CLI. Its auth
state lives under `seita`'s `~/.claude/`, so the service must run as `seita` rather than a
dedicated/dynamic user.

## PATH injection for the `claude` CLI

`claude` is installed imperatively via `nix profile install` (`~/.nix-profile`), which
isn't on a systemd unit's default `PATH`. Added via `systemd.services.fukurou-server.path`
(an additive option — becomes `<entry>/bin` entries on `PATH`). `environment.PATH` is
*not* used directly for this, since it collides with the module system's own PATH
definition (`conflicting definition` eval error, confirmed 2026-08-30).

The `claude` CLI's `SessionEnd` hook (`session-end.mjs`) also needs `node`, which is
installed via home-manager (`/etc/profiles/per-user/<user>`) rather than
`~/.nix-profile`, so that path is added to `path` as well — without it, the hook fails
every session with `node: command not found` in the journal (confirmed 2026-08-30).

## GPU: none in the server itself (since 2026-11-08)

`fukurou-server` no longer touches a GPU. STT/TTS run as lfm3-audio inside llama-swap on
the GTX 1660 SUPER, mutually exclusive with `laya`/`jeff` (see
[llama-cpp.md](llama-cpp.md)); VRAM is accounted there and in
[GPU and VRAM budget](../gpu-vram-budget.md). The unit is ordered `after =
llama-cpp.service` only (no `wants`), so it never pulls llama-cpp up or gets restarted by it.

History: until 2026-11-08 whisper.cpp ran via Vulkan, pinned with
`GGML_VK_VISIBLE_DEVICES=1` (Vulkan 1 = 1660 SUPER; Vulkan's order is its own enumeration,
not `nvidia-smi`'s). The pin is kept commented out in `modules/fukurou.nix`; decision doc:
[2026-09-22-fukurou-vulkan-gpu-split](../decisions/2026-09-22-fukurou-vulkan-gpu-split.md)
(superseded).

## Runtime shared libraries

Binaries built via `nix develop` have absolute-path RPATHs baked in (confirmed via `ldd`,
2026-08-30), so no `LD_LIBRARY_PATH` is needed at the systemd-unit level. Since 2026-11-08
there is no VOICEVOX/onnxruntime `dlopen` and no Vulkan dependency; the only requirement is
that `WorkingDirectory` is correct so `config/server.toml` resolves.
