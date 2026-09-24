# GPU driver operations

Overview: [gpu-driver.md](../gpu-driver.md). VRAM budgeting:
[gpu-vram-budget.md](../gpu-vram-budget.md).

## After a driver install or version change

A version change (e.g. 570 → 575) needs a **reboot**, not just `nixos-rebuild switch`.
Until reboot, the loaded kernel module stays on the old version while userspace
(`nvidia-smi`) is already new, giving:

```
Failed to initialize NVML: Driver/library version mismatch
```

During that window `nvidia-gpu-exporter` and any CUDA workload lose the GPU (ollama-style
services fall back to CPU). Reboot to fix.

## After swapping GPU hardware

1. Re-measure the index/PCI table:
   `nvidia-smi --query-gpu=index,name,pci.bus_id --format=csv`
   and update [GPU and VRAM budget](../gpu-vram-budget.md).
2. Update every module keyed to the old indices/PCI address:
   - `modules/llama-cpp.nix`: `CUDA_VISIBLE_DEVICES` per model, and
     `CMAKE_CUDA_ARCHITECTURES` (must match the new card's SM — a mismatch is a CUDA
     error at startup, see [NVIDIA's CUDA GPUs list](https://developer.nvidia.com/cuda-gpus)).
   - `modules/comfyui.nix`: `gpuIndex`.
   - `modules/desktop.nix`: `deviceSection`'s `BusID` (X11 output card).
   - `modules/fukurou.nix`: `GGML_VK_VISIBLE_DEVICES` — **Vulkan's enumeration order is
     independent of the CUDA/`nvidia-smi` order and must be re-measured separately**
     with `vulkaninfo --summary` (do not assume it matches the CUDA index).
3. If the removed/added card changes generation mix, revisit `hardware.nvidia.open` and
   `hardware.nvidia.package` in `modules/gpu.nix` (see [gpu-driver.md](../gpu-driver.md)).

## Fan too loud / too quiet

Adjust the power limit in `modules/gpu.nix`'s `nvidia-power-limit` service (currently
105 W on the 3060 Ti, index 1). See the measurement table in
[2026-09-23 3060 Ti power limit](../decisions/2026-09-23-3060ti-power-limit.md) before
picking a new value — the fan/power/speed trade-off is nonlinear near the top of the
range and flat above 140 W.

## Checks

```sh
nvidia-smi -L                                                # cards present
nvidia-smi topo -m                                            # PCIe topology
nvidia-smi --query-gpu=pcie.link.width.current --format=csv   # link width per card
nvidia-smi -i 1 -q -d POWER                                    # power limit / draw
```
