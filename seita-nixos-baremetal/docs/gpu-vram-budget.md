# GPU and VRAM budget

Which service uses how much of this host's 2 GPUs. Spans several modules
(`modules/llama-cpp.nix`, `modules/fukurou.nix`, `modules/comfyui.nix`,
`modules/openviking.nix`), so this is the single place for it.

**Always measure before adding anything to a card or changing a preset's numbers.**
Every number here is measured; none of them are safe to run on an estimate.

## Card mapping

Index under `CUDA_DEVICE_ORDER=PCI_BUS_ID` (measured with
`nvidia-smi --query-gpu=pci.bus_id`):

| index | card | PCI | VRAM | SM |
|---|---|---|---|---|
| 0 | GTX 1660 SUPER | 00000000:04:00.0 | 6144 MiB (effective ~5745 MiB) | sm_75, no tensor cores |
| 1 | RTX 3060 Ti | 00000000:06:00.0 | 8192 MiB | sm_86 |

llama.cpp models decide which card is shown/hidden per model via `CUDA_VISIBLE_DEVICES`:

- `"1"` = 3060 Ti only (bonsai family)
- `"0"` = 1660 SUPER only (embedding and laya)
- `"0,1"` (both) and `""` (don't initialize CUDA) are also valid values. The
  former was used by the now-removed gemma4; the latter by embedding back
  when it ran on CPU.

**When you swap a GPU**, re-measure this table and also update
`CMAKE_CUDA_ARCHITECTURES` (`75;86`) in `modules/llama-cpp.nix`. A GPU with a
mismatched SM fails with a CUDA error at startup.

Why `-ngl`/`--device` alone aren't enough: ggml creates a CUDA context
(a few hundred MiB) on every visible device, so `bonsai`, which leaves only
410 MiB free on the 3060 Ti, gets hit even by a process that is supposedly
running on CPU. Hiding the card entirely is the reliable fix, and that's only
possible because llama-swap runs each model as a separate process
([background](decisions/2026-09-22-llama-swap-matrix.md)).

## RTX 3060 Ti (index 1)

| resident | amount | source |
|---|---|---|
| `bonsai` (80K ctx, KV q4_0) | almost everything left (~410 MiB free after load) | measured 2026-09-22 |

fukurou-server (478 MiB) was on this card as of 2026-09-21, but was moved to
the 1660 SUPER on 2026-09-22 via `GGML_VK_VISIBLE_DEVICES`
(`modules/fukurou.nix`). The projector HDMI is also wired to this card, so
Xorg's VRAM use adds on top while projecting
([projector decision](decisions/2026-08-25-projector-hdmi-to-3060ti.md)).

ComfyUI (130 MiB idle, measured 2026-09-21) was also pinned to this card; it is
**disabled since 2026-09-24** because with `bonsai` loaded the card sits at ~95%
and ComfyUI's VRAM guard never lets it start
([decision](decisions/2026-09-24-comfyui-disabled.md)).

### bonsai's context ceiling

3060 Ti alone, `ctk = ctv = q4_0`, `np = 1`, `ngl = 99` (2026-09-22, card otherwise empty):

| context | result | usage |
|---|---|---|
| 32768 | OK | 6674 MiB |
| 65536 | OK | 7410 MiB |
| 81920 | OK | 7778 MiB |
| 90112 | fails | |
| 98304 | fails | |

The failure is not OOM but
`llama_init_from_model: failed to initialize the context: failed to allocate compute pp buffers`
(can't allocate the compute buffer). **81920 is the measured ceiling — do not
raise it even if other resident usage drops.**

- Generation speed: 32.75 tok/s (80K, 200 tokens generated). Barely below the
  33.4-33.8 tok/s of q8_0 / 32768 (KV quantization doesn't bottleneck
  generation). The only cost is KV precision (q8_0 -> q4_0).
- Putting zero layers on the 1660 SUPER is worth 1.3-1.5x on generation and
  2.5-3.7x on prompt processing (the 1660 SUPER has no tensor cores).
- `bonsai-vision` drops context to 8192 because of the mmproj's +600 MB.
- **Do not drop `-np 1`.** `llama-server`'s default of 4 parallel slots
  allocates recurrent-state cache per slot, multiplying VRAM use several
  times over even at the same context, and OOMs the 27B. The embedding model
  keeps the default of 4 since it has no per-slot growing state.

### Why 410 MiB free is fine

Because no other process can touch the 3060 Ti. `embedding`/`laya` physically
can't see this card (`CUDA_VISIBLE_DEVICES=0`), and the only other model that
uses the 3060 Ti (`bonsai-vision`) is always started by the matrix only after
evicting `bonsai`.

### fukurou/ComfyUI's residency is not "overlooked headroom" (verified as of 2026-09-21)

The migration work's measurements (33.6 tok/s, ceilings like 32768 OK / 36864
OOM at the time) were all taken with both of these resident on the card. On
2026-09-21, `bonsai` was reloaded with fukurou/ComfyUI still resident and
reproduced 33.8 tok/s (7330/8192 MiB after load).

So the presets don't need to be discounted for these two. Conversely, stopping
fukurou or ComfyUI only adds headroom — **that is not a reason to raise a
preset.**

## GTX 1660 SUPER (index 0)

Measured 2026-09-23. nvidia-smi reports 6144 MiB total capacity, but after
driver reservation the effective capacity is ~5745 MiB (what PyTorch reports
as "total capacity of 5.61 GiB").

| resident | amount |
|---|---|
| fukurou (whisper.cpp, pinned by `modules/fukurou.nix`) | 479 MiB |
| `embedding` (Qwen3-Embedding-4B Q4_K_M, `-c 8192`) | 3926 MiB |
| `laya` (Laya multilingual 322M, fp16) | ~748 MiB (reference value, varies) |
| **total** | **~5153 MiB** |
| free | ~590 MiB (less while Laya is busy) |

- **Laya's figure is a reference value, not a fixed size.** 748 MiB was measured right
  after loading (2026-09-23); its footprint changes with the requests it handles
  (1128 MiB was observed on 2026-09-24 after use, leaving ~210 MiB free). Treat the
  free space on this card as a range, not a number.
- The remaining headroom is thin, so always measure before adding anything to this card.
- If something stops starting, first lower `embedding`'s `ngl`, or fall back
  to CPU with `CUDA_VISIBLE_DEVICES=""` + `-ngl 0`. CPU execution was still
  usable at 66 ms/request.
- `laya` at fp32 is 1318 MiB and does not fit here. Why it runs at fp16:
  [Laya's decision record](decisions/2026-09-23-laya-in-llama-swap.md).
