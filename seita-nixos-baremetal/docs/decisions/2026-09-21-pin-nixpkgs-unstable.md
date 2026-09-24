# 2026-09-21: pin `nixpkgs-unstable` to a specific revision

## Decision

`flake.nix`'s `nixpkgs-unstable` input is pinned to a fixed revision
(`20b1ddd1aa5ace70c9468305030aa4f9ef79671b`, 2026-09-19) instead of tracking
`nixos-unstable` as a moving branch. The unpinned form is kept commented out next
to it as the "how to go back" note.

## Why

This host cannot build `nodejs` from source: inside the Nix sandbox, nodejs's
`parallel/test-fs-cp-async-file-modes` test fails a `chmod` on a setuid bit:

```
Error: EPERM: operation not permitted, chmod '.../copy_%1/suid'
```

(Confirmed 2026-09-21 that this isn't a ZFS mount-option issue — `/tmp` and `/`
are ZFS with `setuid=on`, not `nosuid`.)

`modules/llama-cpp.nix`'s nixpkgs `llama-cpp` package builds its web UI with npm,
which pulls in `nodejs_latest` unconditionally. So if the unstable input lands on a
revision whose `nodejs-slim` isn't in the binary cache, the whole system becomes
unbuildable — Hydra only builds specific channel revisions, so cache presence has
nothing to do with how recent a revision is. `nixos-unstable` is a moving,
always-green branch, which means "the build breaks on some future day for no
visible reason in this repo" without a pin. This actually happened on 2026-09-21
with the previous pin (`e554fab7`, 2026-09-17).

## Required check before bumping this revision

Confirm `nodejs-slim` is in the binary cache before adopting a new revision:

```sh
nix path-info --store https://cache.nixos.org <nodejs-slim's out path>
```

Do not adopt a revision where this returns null.

## Why `20b1ddd` (2026-09-19) was chosen

`nodejs-slim` 26.9.0 was cached at this revision, and a full `toplevel` build of
this configuration was confirmed to succeed on the real machine. The only
package-level diff against the previous pin (checked by evaluating and diffing
both revisions) was `opencode` 1.18.30 -> 1.18.31 and `ollama-cuda` 0.34.0 ->
0.34.2.
