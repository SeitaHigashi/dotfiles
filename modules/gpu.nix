{ config, lib, pkgs, ... }:

##############################################################################
# NVIDIA GPU (プロプライエタリドライバ)。
#
# 何のために入れるか:
#   このホストはデスクトップではありません。X も Wayland も動かしません。
#   目的は「GPU を計算資源として使えるようにすること」と
#   「GPU の状態を監視できるようにすること」の 2 点です。
#     - 将来の Ollama (CUDA 推論)
#     - modules/monitoring.nix の nvidia-gpu-exporter (nvidia-smi を叩く)
#
# 2 枚差しについて:
#   GTX 1660 SUPER (Turing / 6 GiB) と RTX 4060 (Ada / 8 GiB) を混載し、
#   2 枚またぎで大きめのモデルを載せる想定です。世代が違っても
#   同一の production ドライバ系列が両方をカバーするため、設定は 1 つで済みます。
#
#   ただし性能面では注意が必要です:
#     - 層分割推論では遅い側 (1660 SUPER) が律速します。合計 VRAM は増えますが
#       速度は 4060 単体より落ちることがあります。
#     - 1660 SUPER は Turing でも FP16 テンソルコアを持たない TU116 です。
#     - PCIe レーンがマザーボード側で分割され、片方が x4 に落ちることがあります。
#       2 枚目を挿したら必ず `nvidia-smi topo -m` で実測してください。
#   これらは「入れてみて監視して判断する」ための土台であって、
#   速くなることが保証された構成ではありません。
##############################################################################

{
  ############################################################################
  # unfree の許可
  #
  # NVIDIA のドライバは非フリーなので、明示的に許可しないとビルドが止まります。
  # 全面的に allowUnfree = true にはせず、NVIDIA 関連だけを通します。
  # (うっかり別の非フリーパッケージが混入するのを防ぐため)
  ############################################################################
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "nvidia-x11"
      "nvidia-settings"
      "nvidia-persistenced"
    ];

  ############################################################################
  # ドライバ
  #
  # videoDrivers に "nvidia" を入れるのが NixOS でのドライバ導入の作法です。
  # X を起動しない構成でもこれで kernel module と nvidia-smi が入ります。
  # (X サーバ自体は services.xserver.enable = true にしない限り動きません)
  ############################################################################
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics.enable = true;

  hardware.nvidia = {
    # production 系列を使う。
    # latest ではなく production にするのは、カーネル更新との組み合わせで
    # ビルドが壊れる頻度が明らかに低いためです。Turing と Ada の両方を
    # 1 つのドライバでカバーできます。
    package = config.boot.kernelPackages.nvidiaPackages.production;

    # オープンカーネルモジュールは使わない。
    # Turing (1660 SUPER) は対応世代の境界にあたり、GeForce Turing での
    # 実績はプロプライエタリ版の方が厚いためです。
    # 4060 単体構成に移行したら true を検討してください。
    open = false;

    modesetting.enable = true;

    # nvidia-persistenced を常駐させる。
    #
    # これが無いと、GPU を使うプロセスが 1 つも居ない間ドライバがアンロードされ、
    # nvidia-smi を叩くたびに初期化が走ります。監視で 30 秒おきに叩く構成では
    # 無駄な初期化コストが乗るうえ、メトリクスが一瞬欠けることがあります。
    nvidiaPersistenced = true;

    # 電源管理は無効のまま。
    # ノート PC 向けの機能で、デスクトップの常時稼働サーバでは
    # サスペンド復帰まわりの不具合を持ち込むだけです。
    powerManagement.enable = false;
  };

  ############################################################################
  # 運用メモ
  #
  #   枚数と型番 : nvidia-smi -L
  #   PCIe 幅    : nvidia-smi topo -m
  #                nvidia-smi --query-gpu=pcie.link.width.current --format=csv
  #   利用状況   : nvidia-smi
  #
  # ドライバを入れた直後は再起動が必要です (カーネルモジュールのため)。
  # nixos-rebuild switch だけでは nvidia-smi が動かないことがあります。
  ############################################################################
}
