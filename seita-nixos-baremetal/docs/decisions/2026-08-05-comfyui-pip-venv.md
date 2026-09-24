# ComfyUI: pip venv, fixed system user, dpool dataset

- Decided: 2026-08-05
- Module: `modules/comfyui.nix`

## Why pip venv instead of a nixpkgs package

No `comfyui`/`comfy-cli` package exists in nixpkgs (stable or unstable) as of 2026-08-05,
confirmed via `nix search`. `comfy-cli` is a PyPI-distributed CLI whose job is to pip-install
ComfyUI itself into a venv it manages. Nix's role here is reduced to providing
`python3`/`uv` and a systemd unit to launch the result — unlike ollama/n8n/open-webui,
which are proper nixpkgs/overlay packages. This is the first "pip-venv-managed service"
pattern in this repo.

## Why a fixed system user, not `DynamicUser`

Two units — `comfyui-setup` (venv build) and `comfyui` (server) — read and write the same
directory (`/var/lib/comfyui`). `DynamicUser` assigns a new UID per invocation, which
would complicate keeping permissions consistent across units. Single-unit services like
`ollama`/`victoriametrics` don't have this problem since only one unit ever touches their
data. A fixed user (same pattern as `discord-bot`) keeps this to ordinary Unix
permissions, declared via `systemd.tmpfiles.rules`.

## Why the dpool dataset, not rpool

Checkpoints are large and grow without bound; rpool is a single vdev with no redundancy,
and this was judged not worth risking for image-model weights. This is a capacity/
redundancy trade-off, not the SMR-HDD write-latency reasoning that keeps Minecraft on
rpool — ComfyUI's I/O profile is large, infrequent, non-realtime, so dpool's
characteristics are a fine fit; the trade-off accepted is checkpoint *load* being
somewhat slower than on the SSD-backed rpool.
