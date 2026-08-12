{ lib, ... }:

##############################################################################
# unfree パッケージの許可一覧。
#
# nixpkgs.config.allowUnfreePredicate は関数なのでモジュール間でマージできず、
# 2 箇所で定義すると衝突エラーになります。そのため個別許可が要る unfree
# パッケージはすべてここに集約します (全面的な allowUnfree = true にはせず、
# うっかり別の非フリーパッケージが混入するのを防ぐため)。
##############################################################################

{
  nixpkgs.config.allowUnfreePredicate =
    pkg:
    let
      name = lib.getName pkg;
    in
    builtins.elem name [
      # NVIDIA のプロプライエタリドライバ (modules/gpu.nix)。
      "nvidia-x11"
      "nvidia-settings"
      "nvidia-persistenced"

      # n8n は Sustainable Use License (再配布不可) で非フリー扱い (modules/n8n.nix)。
      "n8n"

      # Open WebUI は 0.6.x では MIT でしたが、独自の Open WebUI License に
      # 変わり非フリー扱いになりました (ブランド表示の除去や一定規模を超える
      # 利用に制限がかかる条項が入っています)。modules/ollama.nix で
      # unstable 版を使うためにここでの許可が要ります。
      "open-webui"

      # Brave ブラウザは公式ビルドの配布条件 (商標・再配布条件) により
      # nixpkgs では unfree 扱い (modules/unstable.nix)。
      "brave"
    ]
    # CUDA ランタイム (ollama-cuda が引く cuda_cudart / libcublas / ...) も
    # NVIDIA の非フリーライセンスです。個数が多く名前も版ごとに増減するため、
    # 1 つずつ列挙せず接頭辞で通します。それでも allowUnfree = true より
    # ずっと狭い許可です。
    || lib.hasPrefix "cuda" name      # cuda_cudart, cuda_cccl, cuda_nvcc, ...
    || lib.hasPrefix "libcu" name     # libcublas, libcurand, libcusparse, ...
    || lib.hasPrefix "libnv" name     # libnvjitlink, libnvidia-container, ...
    || builtins.elem name [ "cudnn" "nccl" ];
}
