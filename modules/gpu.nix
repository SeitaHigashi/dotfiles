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
# 2 枚差しについて (実機で確認済み):
#     GPU 0  GTX 1660 SUPER (Turing TU116 / 6 GiB) — PCIe x4
#     GPU 1  RTX 3060 Ti    (Ampere GA104 / 8 GiB) — PCIe x8
#   合計 VRAM 14 GiB。世代が違っても production ドライバ 1 つで両方カバーされます。
#
#   ただし 2 枚またぎの推論には次のハンデがあります。速くなることが
#   保証された構成ではなく、「監視しながら判断する」ための土台です。
#     - 層分割では遅い側 (1660 SUPER) が律速します。合計 VRAM は増えても
#       速度は 3060 Ti 単体より落ちることがあります。
#     - 1660 SUPER は Turing でも FP16 テンソルコアを持たない TU116 です。
#       3060 Ti にはテンソルコアがあるため、性能差は世代差以上に開きます。
#     - PCIe レーンが分割され、実測で x4 / x8 でした (どちらも物理は x16)。
#       層分割ではカード間の転送が効くので、遅い方が x4 なのは不利に働きます。
#       確認: nvidia-smi --query-gpu=name,pcie.link.width.current --format=csv
#
#   1660 SUPER を外して 3060 Ti 単体にした方が速い可能性は十分あります。
#   モデルを載せたら、Grafana の「GPU 使用率 (カード別)」で
#   両方が均等に回っているかを見て判断してください。
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
    # 1660 SUPER を外して 3060 Ti 単体構成にしたら true を検討してください。
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
