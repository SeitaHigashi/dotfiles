# nix-ld for the Claude Code remote CLI

2026-10-14. Context: connecting to this host from Claude Code remote-control failed with
`Couldn't install the Claude CLI on the remote (cli archive): the host couldn't run the installed
Claude CLI [CLI_NOT_RUNNABLE]`.

## Cause

remote-control downloads a generic glibc CLI into `~/.claude/remote/ccd-cli/` and probes it with
`--version`. On NixOS `/lib64/ld-linux-x86-64.so.2` was `stub-ld`, which only prints
"NixOS cannot run dynamically linked executables intended for generic linux environments", so the probe
failed and the CLI was discarded (`server -install` returned `"cliPath":""`).

## Decision

- `programs.nix-ld.enable = true` in `configuration.nix`. `/lib64/ld-linux-x86-64.so.2` then points at
  `nix-ld`, which loads generic binaries using the libraries in `NIX_LD_LIBRARY_PATH`.
- Verified after switch: `server -probe-cli` exits 0 and the CLI reports `2.1.295`.
- No extra `programs.nix-ld.libraries` were needed. Add them if a future generic binary reports a
  missing `.so`.
- Way back: set `enable = false` (generic binaries stop running again).
