{ config, lib, pkgs, ... }:

##############################################################################
# NVIDIA GPU (プロプライエタリドライバ)。
#
# 何のために入れるか:
#   目的は「GPU を計算資源として使えるようにすること」と
#   「GPU の状態を監視できるようにすること」の 2 点です。
#     - Ollama / ComfyUI (CUDA 推論)
#     - modules/monitoring.nix の nvidia-gpu-exporter (nvidia-smi を叩く)
#   2026-08-11 に表示専任として増設した GT1030 は 2026-08-12 に撤去しました。
#   プロジェクター投影 (X, modules/desktop.nix, KDE Plasma) は 2026-08-12 に
#   1660 SUPER の HDMI 出力に繋いでいましたが、2026-08-25 に 3060 Ti の HDMI
#   出力へ繋ぎ変えました。このカードが表示と計算 (Ollama/ComfyUI) を兼務します。
#
# 2 枚差しについて (実機で確認済み。GPU 番号は CUDA_DEVICE_ORDER=PCI_BUS_ID の並び):
#     GPU 0  GTX 1660 SUPER (Turing TU116 / 6 GiB) — PCIe x4、計算専任
#     GPU 1  RTX 3060 Ti    (Ampere GA104 / 8 GiB) — PCIe x8、計算 + 表示 (HDMI)
#   計算用の合計 VRAM は 14 GiB (0+1)。世代が違っても production ドライバ
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
#     - 3060 Ti は投影中は X (Xorg) にも VRAM と演算を取られます。しかも
#       ComfyUI の計算専任カード (modules/comfyui.nix の gpuIndex) でもあるため、
#       投影しながら ComfyUI を動かすと VRAM 衝突のリスクが上がります
#       (comfyui-vram-guard は使用率ベースなので X の消費分も検知はしますが、
#       閾値に達しやすくなる点は変わりません)。
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
  # 3060 Ti の電力上限 (ファン騒音の低減)
  #
  # 何のために入れるか:
  #   騒音対策です。性能のためではありません。ストック設定では bonsai の
  #   推論中にファンが 93% まで回り、その状態で常用するには音が大きすぎます。
  #
  # 2026-09-23 の実測 (bonsai 27B を llama-server に流し続け、各点 150-300 秒
  # 保持して落ち着いた値。ファン回転数は nvidia-smi の fan.speed):
  #
  #     上限      実電力   ファン   温度   生成 tok/s
  #     (none)    135 W     93 %    82 C     29.3
  #     140 W     135 W     94 %    82 C     29.1
  #     130 W     129 W     92 %    80 C     28.3
  #     120 W     119 W     79 %    79 C     27.2
  #  →  105 W     104 W     60 %    79 C     25.0
  #     100 W      99 W     54 %    78 C     23.8
  #
  #   105 W を選んだ理由: ファン 93% → 60% と引き換えに、生成速度の低下が
  #   15% に収まるため。100 W まで落としてもファンは 6 ポイントしか下がらず、
  #   速度は更に 1.2 tok/s 失います。
  #
  # ★ 温度ではなくワット数で効きます ★
  #   当初はファンに温度閾値 (75 C 付近) があると見て探しましたが、ありません。
  #   このカードは GPU Target Temperature = 83 C を保つようファンを回すので、
  #   1350 MHz 以上ではクロックを変えても温度は 79-82 C でほぼ一定のまま、
  #   ファン回転数だけが変わります。回転数を決めているのは捨てる熱量、
  #   つまりワット数で、95 W → 137 W の範囲でおよそ 1 %/W の直線関係でした。
  #   したがって静音化の制御変数は電力上限が適切です。
  #
  #   クロック固定 (nvidia-smi -lgc) でも同じ電力なら同じ静粛性になりますが、
  #   採りませんでした。-lgc は高負荷後にファンが下がるまで 20 ポイント以上
  #   遅れるヒステリシスがあり、-pl にはそれがほぼ無いためです。-pl は
  #   軽い処理では全速で回れる点も有利です。
  #
  #   なお 140 W 以上を指定しても意味がありません。そこから先は温度側 (82 C)
  #   が律速し、実電力は 135 W で頭打ちになります。
  #
  # 設定可能な範囲は 100.00 - 200.00 W (1 W 刻み)。既定は 200 W。
  #   確認: nvidia-smi -i 1 -q -d POWER
  #
  # ★ 揮発するので systemd で入れ直す必要があります ★
  #   -pl は nvidia-persistenced を有効にしていても再起動で既定値に戻ります。
  #
  # GPU 1 = RTX 3060 Ti です。nvidia-smi の -i は PCI バス順で、この番号は
  # このファイル冒頭の対応表と同じです (GPU 0 = 1660 SUPER)。1660 SUPER には
  # 何もしていません — 埋め込み専任で、そもそも高負荷が続かないためです。
  ############################################################################
  systemd.services.nvidia-power-limit = {
    description = "Cap the RTX 3060 Ti power limit to reduce fan noise";
    after = [ "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -i 1 -pl 105";
      # 既定値に戻す。switch で無効化したときに 105 W が残らないようにします。
      ExecStop = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -i 1 -pl 200";
    };
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
