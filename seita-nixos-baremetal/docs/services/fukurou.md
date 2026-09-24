# fukurou

Implementation: [`modules/fukurou.nix`](../../modules/fukurou.nix)

## What it is

fukurou is a self-developed Rust voice-conversation loop app (`~/fukurou`, developed on
this host). `fukurou-server` runs STT (whisper.cpp) → LLM (`claude` CLI) → TTS (VOICEVOX
core). `fukurou-webui` is a push-to-talk browser test page for it (a development test page
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

Not packaged in nixpkgs. `~/fukurou` (a working checkout on this host) is used directly as
`WorkingDirectory`, and the systemd unit's `ExecStart` runs the already-built
`target/release/` binary — the same "Nix only manages process lifecycle" pattern as
`modules/comfyui.nix`'s pip venv. Rebuild manually:

```sh
cd ~/fukurou && nix develop --command cargo build --release -p fukurou-server -p fukurou-webui
sudo systemctl restart fukurou-server fukurou-webui
```

## Why `User = seita`, not `DynamicUser`

`llm.backend = "claude"` (`config/server.toml`) shells out to the `claude` CLI. Its auth
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

## GPU: Vulkan, not CUDA — and a different index order

whisper.cpp (STT) uses the GPU through Vulkan only (`ldd` shows only `libvulkan.so.1`, no
CUDA/cuBLAS — confirmed 2026-09-22), so `CUDA_VISIBLE_DEVICES`/`CUDA_DEVICE_ORDER` (used
by `modules/ollama.nix`, `modules/llama-cpp.nix`) have **no effect** on this unit.
`GGML_VK_VISIBLE_DEVICES=1` pins it to the GTX 1660 SUPER instead, freeing the RTX 3060 Ti
for llama.cpp's model. **Vulkan's device index is its own enumeration, not
`nvidia-smi`'s** — on this host it happens to be the reverse:

| Vulkan index | Card | `nvidia-smi` index |
|---|---|---|
| 0 | RTX 3060 Ti | 1 |
| 1 | GTX 1660 SUPER | 0 |
| 2 | llvmpipe (Mesa software, CPU) | — |

Measured via `vulkaninfo --summary`, 2026-09-22. This happens to match CUDA's
`FASTEST_FIRST` ordering, but the two are unrelated systems — don't infer one from the
other after a GPU swap; re-measure both (see [runbooks/gpu.md](../runbooks/gpu.md)).

fukurou holds ~478 MiB on the 1660 SUPER while idle (measured 2026-09-22) — see
[GPU and VRAM budget](../gpu-vram-budget.md) for the rest of that card's budget.
**Unverified**: whether VOICEVOX core's onnxruntime also touches the GPU — the 478 MiB
measured lines up with the STT model size alone (`ggml-small.bin` = 465 MB) and doesn't
obviously include a second GPU consumer, but this hasn't been confirmed either way. If
onnxruntime does use the GPU, `GGML_VK_VISIBLE_DEVICES` won't control it (that would need
an onnxruntime execution-provider setting instead) — re-check with a per-card
`nvidia-smi` breakdown after any change here.

No VRAM contention guard exists for fukurou (unlike ComfyUI's `comfyui-vram-guard`) —
voice conversation is short, one-shot inference, so the expected failure mode is a load
delay, not sustained contention. Revisit if that assumption breaks.

## Runtime shared libraries

Binaries built via `nix develop` have absolute-path RPATHs baked in (confirmed via `ldd`,
2026-08-30), so no `LD_LIBRARY_PATH` is needed at the systemd-unit level for things like
`libvulkan.so.1`. VOICEVOX core / onnxruntime's `.so` files are `dlopen`'d by the app
itself from a path relative to `config/server.toml` (`models/voicevox_core/...`) — the
only requirement is that `WorkingDirectory` is correct.
