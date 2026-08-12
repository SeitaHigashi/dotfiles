{ config, lib, pkgs, ... }:

##############################################################################
# NVIDIA GPU (プロプライエタリドライバ)。
#
# 何のために入れるか:
#   目的は「GPU を計算資源として使えるようにすること」と
#   「GPU の状態を監視できるようにすること」の 2 点です。
#     - Ollama / ComfyUI (CUDA 推論)
#     - modules/monitoring.nix の nvidia-gpu-exporter (nvidia-smi を叩く)
#   2026-08-11 に GT1030 を表示専任として増設し、X (modules/desktop.nix,
#   KDE Plasma) はこのカードだけを使います。以下の計算用途の記述は
#   1660 SUPER / 3060 Ti の 2 枚 (GT1030 を含まない) についてのものです。
#
# 3 枚差しについて (実機で確認済み。GPU 番号は CUDA_DEVICE_ORDER=PCI_BUS_ID の並び):
#     GPU 0  GTX 1660 SUPER (Turing TU116 / 6 GiB) — PCIe x4、計算用
#     GPU 1  GT 1030        (Pascal GP108)          — 表示専任 (modules/desktop.nix)
#     GPU 2  RTX 3060 Ti    (Ampere GA104 / 8 GiB) — PCIe x8、計算用
#   計算用の合計 VRAM は 14 GiB (0+2)。世代が違っても production ドライバ
#   1 つで全カードをカバーできます。
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
  # unfree の許可は modules/unfree.nix に集約 (NVIDIA ドライバ・CUDA を含む)。

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
    # beta (575.51.02) を使っています。
    #
    # 本来の方針は production (570.195.03) でした。カーネル更新との
    # 組み合わせでビルドが壊れる頻度が明らかに低いためです。beta にしたのは
    # modules/ollama.nix が unstable の ollama-cuda を使い、それが
    # CUDA 12.9 を引くからです。25.05 の production/latest/stable はいずれも
    # 570 系 (CUDA 12.8 相当) で、CUDA 12.9 のユーザー空間ライブラリとは
    # バージョンが揃いません。
    #
    # CUDA の minor version compatibility があるので 570 のままでも動く公算は
    # 高いのですが、12.9 で追加された API を使われた時点で実行時エラーになります。
    # 推論が主目的のホストなので、そこを賭けずに揃えました。
    #
    # 代償: beta はカーネル更新で production より壊れやすい系列です。
    # rebuild で nvidia のビルドが失敗したら、まずここを production に戻し、
    # 合わせて modules/ollama.nix の package を stable の pkgs.ollama-cuda に
    # 戻してください (CUDA 12.8 側で揃います)。
    #
    # Turing (1660 SUPER) と Ampere (3060 Ti) は 1 つのドライバでカバーされます。
    package = config.boot.kernelPackages.nvidiaPackages.beta;

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
  # /sbin/ldconfig の互換シンボリックリンク
  #
  # NixOS には /sbin/ldconfig が存在しません (共有ライブラリのキャッシュは
  # Nix store の rpath で解決するため、glibc の ldconfig 自体は運用上不要)。
  # ところが triton (torch のカーネル JIT) は CUDA ライブラリの検索先を得るのに
  # `/sbin/ldconfig -p` を絶対パスで直接叩くため、パスが無いと
  # `FileNotFoundError: [Errno 2] No such file or directory: '/sbin/ldconfig'`
  # で落ちます (modules/comfyui.nix 経由の ComfyUI で実際に発生・確認済み)。
  # PATH ではなく絶対パス呼び出しなので systemd unit 側の `path = [...]` では
  # 解決できず、ファイルシステム上に実体を置く必要があります。
  #
  # 同様の絶対パス呼び出しは xformers / bitsandbytes など他の CUDA 系
  # Python パッケージにもある既知のパターンのため、単一サービス
  # (comfyui.nix) ではなくここ (GPU/CUDA の土台) に置きます。
  systemd.tmpfiles.rules = [
    "d /sbin 0755 root root -"
    "L+ /sbin/ldconfig - - - - ${pkgs.glibc.bin}/bin/ldconfig"
  ];

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
  #
  # バージョンを変えた時 (570 → 575 など) は特に注意してください。switch 後
  # 再起動するまで、動いているカーネルモジュールは旧版のまま、nvidia-smi は
  # 新版という食い違いが起きます。この間は
  #   Failed to initialize NVML: Driver/library version mismatch
  # となり、nvidia-gpu-exporter も ollama も GPU を掴めません
  # (ollama は GPU が無いものとして CPU 推論に落ちます)。
  # 再起動すれば解消します。
  ############################################################################
}
