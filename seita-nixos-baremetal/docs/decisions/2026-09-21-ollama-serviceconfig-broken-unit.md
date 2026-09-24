# 2026-09-21: keep the ollama resource-priority block commented out, not deleted

## Decision

`modules/resource-priority.nix`'s `ollama.serviceConfig` block (`CPUWeight = 20;
MemoryHigh = "12G";`) is commented out to match `services.ollama.enable = false`
in `modules/ollama.nix` — see
[2026-09-23 ollama to llama.cpp migration](2026-09-23-ollama-to-llama-cpp.md).
It must stay commented, not be deleted, and not be re-enabled without also
re-enabling `services.ollama`.

## Why leaving it uncommented breaks the host

When `services.ollama.enable = false`, the `ollama.service` unit itself is no
longer generated. But `systemd.services.ollama.serviceConfig = { ... }` in
`modules/resource-priority.nix` is a separate NixOS module option — it doesn't
know the unit it's attached to no longer exists. If left active, it generates a
broken unit file under `/etc/systemd/system` with no `ExecStart`, confirmed on the
real host. Nothing starts it, but `node_exporter` keeps reporting it as `inactive`
(rather than absent), which makes `modules/alerting.nix`'s liveness monitoring
alert continuously for a service that was never supposed to run.

When re-enabling `services.ollama`, restore this block at the same time.
