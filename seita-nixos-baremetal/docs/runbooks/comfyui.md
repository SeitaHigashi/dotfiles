# ComfyUI operations

Overview: [services/comfyui.md](../services/comfyui.md).

## Setup/runtime gotchas hit on real hardware

These are baked into `comfyui-setup.service`'s script and `comfyui.service`'s
environment; listed here in case they need to be reproduced or re-diagnosed.

### `comfy-cli` needs `git` on PATH

`comfy-cli` imports GitPython (`workspace_manager.py`) at import time and dies with
`ImportError` if `git` isn't on `PATH` (same class of problem as n8n's node PATH
injection). Fixed via `systemd.services.comfyui-setup.path = [ pkgs.git ]` (also needed by
`comfyui.service` itself at launch).

### ComfyUI's own venv has no `pip`

`comfy install` creates a nested venv (`ComfyUI/.venv`) the `uv venv` way, which doesn't
include `pip`. ComfyUI-Manager's `manager_util.get_pip_cmd()` tries `python -m pip` first
and fails without it. Fixed in the setup script:

```sh
${stateDir}/ComfyUI/.venv/bin/python -m ensurepip --upgrade
```

### ComfyUI-Manager silently pins `use_uv=true` and then fails

On first run (no `config.ini` yet), `manager_core.py`'s `read_config()` swallows
exceptions and auto-detects `use_uv` via `find_spec("uv") is not None`. ComfyUI's own
`requirements.txt` pulls in the PyPI package named `uv` (a wrapper bundling a manylinux
binary), so this check is always `True` and gets written to `config.ini` permanently.

With `use_uv=true`, ComfyUI-Manager never tries `python -m pip` — instead: (1) tries
`python -m uv` (the bundled generic-manylinux binary, blocked by NixOS's absence of a
standard dynamic linker path), (2) silently falls back to the `uv` on `PATH` (the nixpkgs
one, itself fine) — but on this host step (2) still failed with
`Command '['uv', 'pip', 'freeze']' returned non-zero exit status 127` (root cause
unconfirmed, likely something left over from step (1)'s stub-ld failure). Net effect:
ComfyUI failed to start every time. Installing `pip` alone doesn't fix this — the
auto-detection itself has to be defeated by writing `use_uv=false` into `config.ini`
explicitly, which the setup script does via a small Python snippet.

### triton needs a C compiler

triton (torch's kernel JIT) compiles wrapper kernels with a C compiler at runtime; the
venv ships none. Fixed by adding `pkgs.gcc` to `comfyui.service`'s `path` and setting
`CC` explicitly (triton prefers the `CC` env var when present).

### CUDA device order mismatch

`nvidia-smi`'s PCI-bus-order numbering (index 0 = 1660 SUPER, index 1 = 3060 Ti) differs
from CUDA's default `FASTEST_FIRST` enumeration. With only `CUDA_VISIBLE_DEVICES=1` set,
torch grabbed the 1660 SUPER instead (`Device: cuda:0 NVIDIA GeForce GTX 1660 SUPER` in
the log) — the opposite of intended. Fixed by also setting
`CUDA_DEVICE_ORDER=PCI_BUS_ID`, which aligns torch's numbering with `nvidia-smi`'s and
with what `comfyui-vram-guard` queries via `nvidia-smi -i 1`.

### Missing `libstdc++`

pip's torch bundles its own CUDA runtime but still dynamically links `libstdc++.so.6`,
which doesn't exist as a system library on NixOS (no `/usr/lib`). Fixed by adding
`pkgs.stdenv.cc.cc` to `LD_LIBRARY_PATH` alongside `/run/opengl-driver/lib`.

### triton can't find `libcuda.so` via ldconfig

triton locates `libcuda.so` by parsing `/sbin/ldconfig -p`'s output. NixOS doesn't
maintain an `ld.so.cache`, so even with the `/sbin/ldconfig` shim
(`modules/gpu.nix`) present, this fails with
`Can't open cache file ... No such file or directory`. Bypassed entirely by setting
`TRITON_LIBCUDA_PATH=/run/opengl-driver/lib`, which makes triton skip ldconfig lookup.

### triton also needs `ptxas`/`cuobjdump`/`nvdisasm`

These aren't bundled with pip's torch/triton — normally provided by
`nvidia-cuda-nvcc` (pip) or a full CUDA toolkit, neither of which is installed here (only
the driver, via `hardware.nvidia`). Pointed explicitly at the matching nixpkgs
`cudaPackages` derivations (`cuda_nvcc` for `ptxas`; separate packages for `cuobjdump`/
`nvdisasm`) via `TRITON_PTXAS_PATH` / `TRITON_CUOBJDUMP_PATH` / `TRITON_NVDISASM_PATH`.
`allowUnfreePredicate` already covers the `cuda` prefix broadly (`modules/unfree.nix`).

## Checking the VRAM guard

```sh
sudo -u comfyui /nix/store/.../comfyui-vram-guard pre-start   # manual pre-start check
ls /run/comfyui-vram-guard/                                    # stop-flag if force-stopped
```

A manual `systemctl stop comfyui` never sets the stop-flag, so
`comfyui-vram-resume` should do nothing in that case.

## Status/logs

```sh
systemctl status comfyui-setup comfyui comfyui-vram-guard.timer comfyui-vram-resume.timer
journalctl -u comfyui-setup -b
journalctl -u comfyui -b | grep -i cuda
```
