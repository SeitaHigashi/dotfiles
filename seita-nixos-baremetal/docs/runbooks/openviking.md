# OpenViking runbook

Service overview: [docs/services/openviking.md](../services/openviking.md)

## Update the image

```sh
podman pull ghcr.io/volcengine/openviking:latest
systemctl restart podman-openviking
```

## Rotate `root_api_key`

```sh
nix-shell -p openssl age --run '...'   # generate a new key, then re-encrypt it
```

Re-create `secrets/openviking-root-api-key.age` with the new value and rebuild.
`openviking-conf.service` regenerates `ov.conf` from the template on the next start — no manual
edit of `ov.conf` needed.

## Re-enable ollama as the inference backend

Not currently supported without also editing `modules/openviking.nix`'s `inferenceBaseUrl` back to
`http://127.0.0.1:11434/v1` and restoring the ollama-specific request options (`options.num_ctx`
nesting, model names). See
[the ollama-era vlm selection decision](../decisions/2026-09-08-openviking-vlm-selection.md) for
what those options were and why. Re-enabling ollama itself is covered in
[docs/services/ollama.md](../services/ollama.md#how-to-re-enable).
