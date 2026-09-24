# How to build the PrismML fork of llama.cpp

- Date: 2026-09-21
- Scope: `prismSrc`/`llamaCppPrism` in `modules/llama-cpp.nix`

## Why the PrismML fork

Only the PrismML fork (`github:PrismML-Eng/llama.cpp`, branch `prism`) can
decode Bonsai-2's ternary/1-bit packing (PTQ1_0/PQ2_0) — neither upstream
llama.cpp nor ollama has the kernels for it. ollama's model blobs are also a
proprietary format, so nothing is interchangeable between them.

## Decision

Bring only "fetch the fork's source" into this module, and build the
derivation by overriding nixpkgs' (unstable) `llama-cpp`.

- rev/hash must match what's pinned in `~/bonsai-workspaces/flake.lock`
  (**that's the source of truth**). The hash can be the lock's `narHash`
  verbatim (`fetchFromGitHub`'s hash matches the `type = "github"` narHash,
  which is the NAR hash of the expanded tree).
- `patches = [ ]`: nixpkgs' patches assume upstream line numbers and don't
  apply to the fork (same call as bonsai-workspaces made).
- `cudaSupport` is named on the `llama-cpp` override, not set nixpkgs-wide
  (per CLAUDE.md's "don't set `nixpkgs.config.cudaSupport = true`"). The CUDA
  runtime's unfree allow-listing is already covered by `modules/unfree.nix`'s
  `cuda`/`libcu` prefixes (confirmed).
- Restrict `CMAKE_CUDA_ARCHITECTURES` to this host's 2 cards (`75` = 1660
  SUPER, `86` = 3060 Ti). nixpkgs' default is 9 architectures —
  `75;80;86;89;90;100;103;120;121` (confirmed on the host). CUDA codegen
  dominates build time, so on a 4C/8T Ryzen 3 3300X that becomes the entire
  first-switch wait. `libggml-cuda.so` built for 2 architectures is ~98 MB,
  vs. several times that for 9. Not using `nixpkgs.config.cudaCapabilities`
  because it needs a re-import of nixpkgs — a cmakeFlags override is enough.

## Rejected alternatives

### Making it a flake input

The obvious form is `inputs.bonsai.url = "path:/home/seita/bonsai-workspaces";`,
but this doesn't work. `~/bonsai-workspaces` is not a git repository, and a
`path:` flake input copies the entire directory tree into the nix store. With
27 GiB of GGUFs under `models/`, the store would grow by 27 GiB on every eval
(a git repository would only pull in tracked files, which changes the picture).

### Pointing ExecStart directly at a prebuilt binary

The same "Nix only manages process startup" pattern as
`modules/fukurou.nix`/`modules/comfyui.nix`: point directly at
`~/bonsai-workspaces/result-llama/bin/llama-server`. Zero build time, but the
system config would depend on the result of a manual `nix build` outside git,
and deleting the `result` symlink would break the service on GC. Chose the
declarative form since this is meant to run as a resident service.

## Cost

CUDA source builds get no binary cache benefit (it's a fork, not on Hydra).
Store paths also won't match what bonsai-workspaces built, since the nixpkgs
pin differs. Update procedure: [runbooks/llama-cpp.md](../runbooks/llama-cpp.md).
