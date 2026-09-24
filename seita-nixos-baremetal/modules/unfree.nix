{ lib, ... }:

##############################################################################
# The single, only place nixpkgs.config.allowUnfreePredicate is defined.
# It's a function, so it can't be merged across modules — a second definition
# elsewhere is a hard conflict. Individually allowlisted rather than a
# blanket allowUnfree = true, to avoid accidentally pulling in unrelated
# non-free packages. Details and per-package rationale: docs/nixpkgs-channels.md
#
# When you change this file, update docs/nixpkgs-channels.md in the same commit.
##############################################################################

{
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    let
      name = lib.getName pkg;
    in
    builtins.elem name [
      "nvidia-x11" # proprietary NVIDIA driver (modules/gpu.nix)
      "nvidia-settings"
      "nvidia-persistenced"
      "n8n" # Sustainable Use License, non-redistributable (modules/n8n.nix)
      "open-webui" # was MIT through 0.6.x, now the proprietary Open WebUI License (modules/ollama.nix)
      "brave" # unfree per official build's distribution/trademark terms (modules/unstable.nix)
    ]
    # CUDA runtime deps (pulled in by ollama-cuda: cuda_cudart, libcublas, ...)
    # are also NVIDIA's non-free license. Too many, and too version-churny,
    # to list individually — allowed by prefix instead. Still far narrower
    # than allowUnfree = true.
    || lib.hasPrefix "cuda" name      # cuda_cudart, cuda_cccl, cuda_nvcc, ...
    || lib.hasPrefix "libcu" name     # libcublas, libcurand, libcusparse, ...
    || lib.hasPrefix "libnv" name     # libnvjitlink, libnvidia-container, ...
    || builtins.elem name [ "cudnn" "nccl" ];
}
