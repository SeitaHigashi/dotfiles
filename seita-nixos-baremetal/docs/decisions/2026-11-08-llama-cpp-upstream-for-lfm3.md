# Run LFM3-Audio-2B on a side-by-side upstream llama.cpp

- Date: 2026-11-08
- Scope: `upstreamRev`/`llamaCppUpstream`, macro `serverUpstream`, model `lfm3-audio` in `modules/llama-cpp.nix`

## Why

LFM3-Audio-2B (Liquid AI) support was merged into upstream ggml-org/llama.cpp
(PR #31257, release b11960 onward, incl. `/v1/realtime`). The PrismML fork
(`prismRev`, build 11146) predates it and cannot load the model. The fork is
needed for Bonsai-2 (see [prism build](2026-09-21-llama-cpp-prism-build.md)),
so it is not updated; a second build is added instead.

## Decision

- `llamaCppUpstream`: same recipe as `llamaCppPrism` (nixpkgs-unstable
  `llama-cpp`, `cudaSupport = true`, `patches = [ ]`, CUDA archs `75;86`), with
  `src` = ggml-org/llama.cpp at the **v0.9.0** release
  (`cd959bae99ff4bed22bef2604f45241c09bbb8c8`, 2026-11-04). Chosen as a tagged
  release newer than b11960 rather than a moving `bNNNNN` build. Hash from
  `nix-prefetch-url --unpack` converted to SRI.
- New macro `serverUpstream`; only `lfm3-audio` uses it. All other models keep
  `server` (prism) unchanged.
- `lfm3-audio`: `LFM3-Audio-2B-Q4_K_M.gguf` (1.05 GB) + `--mmproj
  mmproj-LFM3-Audio-2B-Q4_K_M.gguf` (164 MB) from `LiquidAI/LFM3-Audio-2B-GGUF`
  in `/var/lib/llm-models/LFM3-Audio-2B-GGUF/`; `CUDA_VISIBLE_DEVICES=0`
  (1660 SUPER), `ttl: 600`, `-c 8192`, `evict_costs` 30.
- Matrix: added as a third alternative `(laya | jeff-qwen3.5-0.8b | lfm3-audio)`
  in all three sets, so bonsai on the 3060 Ti is untouched.

## Open points

- VRAM of `embedding` + `lfm3-audio` on the 1660 SUPER is not measured; the
  card has little headroom (see [gpu-vram-budget](../gpu-vram-budget.md)).
- Upstream pin is independent of `llm/flake.lock`; bump `upstreamRev`/`upstreamHash` by hand.
