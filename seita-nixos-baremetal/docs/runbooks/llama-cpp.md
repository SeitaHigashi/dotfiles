# llama.cpp operations

Service overview: [services/llama-cpp.md](../services/llama-cpp.md).

## Updating the PrismML fork

1. Bump `~/bonsai-workspaces`' `flake.lock` first (**it is the source of truth**).
2. Set `prismRev`/`prismHash` in `modules/llama-cpp.nix` to match that lock.
   The hash can be the lock's `narHash` verbatim. If it's wrong, nix prints
   the expected value — use that.
3. Do the "make sure the build passes before switching" step below.

## Make sure the build passes before switching

The CUDA source build doesn't benefit from a binary cache, and first builds
or updates take a while. Even if `nix build .#llama-cpp-prism-cuda` was
already built in bonsai-workspaces, the nixpkgs pin differs (theirs vs. this
host's `modules/unstable.nix` nixpkgs-unstable), so the store path won't
match and it rebuilds.

```sh
nix build --no-link \
  .#nixosConfigurations.seita-nixos-baremetal.config.system.build.toplevel
```

## Watching Laya's first-run setup

The torch (cu121) wheel is about 2.5 GB, so the first run takes a few
minutes. `nixos-rebuild switch` itself returns without waiting; `laya-setup.service`
runs in the background (30 min timeout).

```sh
journalctl -u laya-setup -f
```

Idempotent: creates the venv if missing, updates it via pip if present, and
skips re-downloading weights already in the HF cache.

## After swapping a GPU

1. Re-measure the mapping with
   `nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv` and update
   [GPU and VRAM budget](../gpu-vram-budget.md).
2. Match each model's `CUDA_VISIBLE_DEVICES` in `modules/llama-cpp.nix` to the new mapping.
3. Match `CMAKE_CUDA_ARCHITECTURES` (`75;86`) to the new card's SM (a
   mismatched SM fails with a CUDA error at startup; see NVIDIA's CUDA GPUs page).
4. fukurou is on a separate track via Vulkan's enumeration order
   (`GGML_VK_VISIBLE_DEVICES` in `modules/fukurou.nix`).

## A model on the 1660 SUPER stops starting

First try lowering `embedding`'s `-ngl`, or fall back to CPU with
`CUDA_VISIBLE_DEVICES=""` + `-ngl 0` (still usable at 66 ms/request on CPU).
Breakdown: [GPU and VRAM budget](../gpu-vram-budget.md#gtx-1660-super-index-0).

## Crash loop

`startLimitBurst = 3` / `startLimitIntervalSec = 300`: gives up after 3
failures in 5 minutes. If it's stopped, run `systemctl reset-failed llama-cpp`
and fix the root cause (usually a VRAM shortage) before starting it again.
