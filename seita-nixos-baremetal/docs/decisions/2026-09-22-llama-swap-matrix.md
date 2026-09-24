# From the fork's own router to llama-swap (matrix)

- Date: 2026-09-22
- Scope: `swapConfig` and `systemd.services.llama-cpp` in `modules/llama-cpp.nix`

## Background

Originally used the PrismML fork's own router mode (`--models-preset` +
`--models-max`). This router's only eviction policy is a slot-count-based
LRU, blind to VRAM and devices. As a result:

- `[bonsai]` on CUDA0 could be evicted even while CUDA1 was free.
- If CPU-bound `[embedding]` got picked by LRU, evicting it freed zero bytes
  of VRAM and still OOMed anyway (measured — this is the direct reason
  `--models-max` had to be dropped to 1).

Both problems come from having no way to express "which models can coexist,"
and no amount of parameter tuning fixes that.

## Decision

Put [llama-swap](https://github.com/mostlygeek/llama-swap) (Go, an
OpenAI/Anthropic-compatible front proxy) in front. It starts `llama-server`
as a child process per model, and coexistence can be written as config. The
fork's binary can be used as-is in `cmd`, so nothing about depending on
PrismML is lost.

### Routing engine: matrix

A group engine (swap/exclusive/persistent) can express "embedding doesn't
evict bonsai," but only that much. This host's real constraint is
fundamentally "which combination fits in VRAM," not a hierarchy of groups.
matrix is a solver that lists the combinations that fit as `sets` and evicts
starting from the lowest `evict_costs`, which maps directly onto the constraint.

The current set is a single one
(`(bonsai | bonsai-vision) & embedding & laya`), so there's no path that
evicts `bonsai`. This follows from removing gemma4/gemma4-32k on 2026-09-22.
gemma4 needed both cards (only 20/49 layers fit on the 1660 SUPER alone, at
an unusable 14.42 tok/s prompt processing — measured 2026-09-22), so bringing
it back would necessarily add a second set that evicts bonsai.
`evict_costs` already has bonsai set high in anticipation of that.

### GPUs assigned per model via CUDA_VISIBLE_DEVICES

Previously specified via `models.ini`'s `device = CUDA0 / CUDA1`, but ggml
creates a CUDA context (a few hundred MiB) on every visible device even when
told not to use it via `--device`. With `[bonsai]` leaving only 410 MiB free
on CUDA0, even the supposedly-CPU embedding process could hit CUDA0 and
crash. Since llama-swap runs each model as a separate process, env vars can
hide a card entirely — something a single-process router can't do in principle.

### CUDA_DEVICE_ORDER: FASTEST_FIRST -> PCI_BUS_ID (reversed)

**Before 2026-09-22 this was FASTEST_FIRST, with a comment saying "do not set
this to PCI_BUS_ID."** Back then `models.ini` referred to cards by CUDA0/CUDA1
names that assumed "fastest first" order; with PCI order, the 27B landed on
the 1660 SUPER and OOMed. Now that cards aren't addressed by device name
anymore, the opposite holds: PCI order, which doesn't depend on a "which one
is faster" heuristic, is the stable choice. Mapping table:
[GPU and VRAM budget](../gpu-vram-budget.md).

`modules/ollama.nix` also sets `CUDA_DEVICE_ORDER = "PCI_BUS_ID"`. Env vars
are per-unit, so the two don't affect each other.

## Other settings, and why

- `globalTTL: 0`: no automatic unload. "Evict when the matrix needs to" is
  simpler than "unload when idle."
- No `--watch-config`: config is a read-only file in the nix store, so
  changes always go through a rebuild. Rebuilding changes ExecStart's store
  path, which systemd treats as a restart trigger.
- The numeric basis (tok/s, context ceilings) all comes from the migration
  work's measurements. When changing them, also check the comments in
  `~/bonsai-workspaces/models.ini`.
