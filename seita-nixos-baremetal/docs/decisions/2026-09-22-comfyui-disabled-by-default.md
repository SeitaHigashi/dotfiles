# ComfyUI stopped by default (`wantedBy = [ ]`)

- Decided: 2026-09-22
- Module: `modules/comfyui.nix` (`comfyui.service`, `comfyui-vram-resume.timer`)

## Decision

`comfyui.service`'s `wantedBy` was changed to `[ ]` (was `[ "multi-user.target" ]`), so it
no longer starts automatically. This frees the RTX 3060 Ti's VRAM for llama.cpp's `bonsai`
model instead — ComfyUI holds ~130 MiB even while idle (measured 2026-09-21), which
`modules/llama-cpp.nix`'s context-size budgeting doesn't have room to spare
(see [GPU and VRAM budget](../gpu-vram-budget.md)).

The `comfyui-vram-resume.timer`'s `wantedBy` was also set to `[ ]` for the same reason:
it's the only path that could restart a stopped ComfyUI automatically (if the guard's
stop-flag were left behind under `/run` from an old force-stop), and with ComfyUI
intentionally off by default, that auto-restart path needs to be closed too.

## Why the module stays wired into `flake.nix` instead of being removed

Removing the module (rather than just disabling the service) would leave
`modules/resource-priority.nix`'s `comfyui.serviceConfig` referencing a unit that no
longer exists, producing a broken unit with no `ExecStart` — this exact failure mode was
hit in practice when `ollama.service` was disabled the same way (see
`modules/resource-priority.nix`'s comments). Keeping the module (with the service just not
auto-started) avoids repeating that.

## How to re-enable

The venv (`/var/lib/comfyui`) and the Tailscale Serve port (9443, in
`modules/reverse-proxy.nix`) are left in place. To use it on demand:

```sh
sudo systemctl start comfyui
```

To go back to always-on, revert both `wantedBy` fields above (`comfyui.service` and
`comfyui-vram-resume.timer`) to `[ "multi-user.target" ]`.
