{ config, lib, pkgs, ... }:

##############################################################################
# Ollama (ローカル LLM 推論サーバ) と Open WebUI。
#
# 何のために入れるか:
#   1. 他のサービス / スクリプトから叩ける HTTP API (11434)
#   2. ブラウザからのチャットとコード補助 (Open WebUI, 8080)
#
# このホストの制約 (modules/gpu.nix も参照):
#     GPU 0  GTX 1660 SUPER  6 GiB  sm_75  PCIe x4
#     GPU 1  RTX 3060 Ti     8 GiB  sm_86  PCIe x8
#   合計 VRAM 14 GiB。CPU は Ryzen 3 3300X (4C/8T)。
#   RAM 46 GiB のうち ZFS ARC に 16 GiB、Minecraft のヒープに 8 GiB を
#   既に割り当てているため、CPU オフロードに使える余地は 20 GiB 程度です。
#
#   現実的な上限は 14B の Q4 量子化まで。32B クラスは VRAM に収まらず
#   CPU にあふれて数 tok/s になり、実用になりません。
#
# コンテナではなくネイティブの systemd サービスにしています。
# podman 側に GPU パススルー (CDI / nvidia-container-toolkit) を用意するより
# services.ollama をそのまま使う方が単純で、壊れる箇所が少ないためです。
##############################################################################

let
  ports = {
    ollama = 11434;
    openWebui = 8080; # monitoring.nix の cadvisor は 8081。衝突しません
  };
in
{
  ############################################################################
  # Ollama 本体
  ############################################################################
  services.ollama = {
    enable = true;

    # unstable の CUDA 版を使う。
    #
    # なぜ unstable か:
    #   25.05 の ollama は 0.11.10 で、unstable は 0.32.4 です。ollama は
    #   モデルの対応状況が本体のバージョンに直結しており、古いままだと
    #   新しいモデルは pull はできても読み込みで落ちます。
    #   ollama はカーネルと結合しないユーザー空間のデーモンなので、
    #   modules/unstable.nix の「葉のパッケージだけ unstable」に合致します。
    #   (unstablePackages のリストではなく、ここで名指しで参照しています。
    #    systemPackages ではなくサービスの package として使うため)
    #
    # なぜ ollama ではなく ollama-cuda か:
    #   既定の pkgs.ollama は nixpkgs.config.cudaSupport を見ますが、
    #   それを立てると nixpkgs 全体が再ビルドになります (modules/gpu.nix 参照)。
    #
    # これは CUDA 12.9 を引きます。NVIDIA ドライバを beta 575 にしているのは
    # そのためです (modules/gpu.nix)。片方を戻すなら両方戻してください。
    package = pkgs.unstable.ollama-cuda;

    # user / group は既定 (null) のまま = DynamicUser で動かします。
    #
    # 静的ユーザーにしても解決しない点に注意してください。25.05 の
    # services.ollama は User= を足すだけで serviceConfig.DynamicUser = true を
    # 常に付けており、systemd は DynamicUser が立っている限り StateDirectory の
    # 実体を /var/lib/private/<名前> に置きます。したがってモデル用の
    # ZFS データセットは /var/lib/private/ollama にマウントしています
    # (VictoriaMetrics と同じ事情。disko/default.nix のコメント参照)。
    # /var/lib/ollama はそこへの symlink になるので、home はこのままで構いません。
    home = "/var/lib/ollama";
    # modelsDir は既定で ${home}/models

    # 待ち受けは 0.0.0.0。到達制御はファイアウォール側 (下記) で行います。
    # Grafana と同じ方針です — Tailscale の IP はビルド時に決まらないため、
    # アドレスではなくインタフェースで絞ります。
    host = "0.0.0.0";
    port = ports.ollama;
    openFirewall = false;

    environmentVariables = {
      ########################################################################
      # GPU 2 枚を束ねて 14 GiB のプールとして使う
      ########################################################################

      # 速い 3060 Ti を先頭にして、層の割り当てで優先させる。
      # (この順序は ollama から見た GPU 番号にも影響します)
      CUDA_VISIBLE_DEVICES = "1,0";

      # 1 枚に収まるモデルでも敢えて 2 枚に分散させる。
      #
      # ★ これは「速くなる」設定ではありません ★
      #   1660 SUPER は PCIe x4 かつ FP16 テンソルコアを持たない TU116 です。
      #   層分割ではカード間転送と遅い側の演算が律速し、3060 Ti 単体より
      #   tok/s が落ちることがあります。7B クラスで遅いと感じたら、
      #   この行を消して CUDA_VISIBLE_DEVICES = "1" に切り戻してください
      #   (3060 Ti 単体構成)。判断材料の取り方は末尾の運用メモに書いています。
      OLLAMA_SCHED_SPREAD = "1";

      ########################################################################
      # VRAM の節約
      ########################################################################
      OLLAMA_FLASH_ATTENTION = "1";

      # KV キャッシュを q8_0 に量子化してほぼ半減させる。
      # 長いコンテキストを扱うときに効きます。sm_75 / sm_86 とも対応。
      # 出力がおかしいと感じたら、まずここを外して切り分けてください。
      OLLAMA_KV_CACHE_TYPE = "q8_0";

      ########################################################################
      # 常駐とスケジューリング
      ########################################################################

      # 14 GiB しかないので、モデルの同時ロードは 1 本に固定。
      # 複数ロードを許すと VRAM を奪い合ってロードとアンロードが往復します。
      OLLAMA_MAX_LOADED_MODELS = "1";

      # 4C/8T なので同時リクエストも絞る。
      # 並列を上げると KV キャッシュの分だけ VRAM も余計に食います。
      OLLAMA_NUM_PARALLEL = "1";

      # API 利用のたびにモデルを読み直さないよう、しばらく常駐させる。
      # ロードは NVMe から数秒かかります。VRAM を空けたいときは短くする。
      OLLAMA_KEEP_ALIVE = "30m";
    };

    # 起動後に自動で pull しておくモデル。
    # 初回の rebuild ではここのダウンロード (計 15 GiB 程度) が走ります。
    loadModels = [
      "qwen2.5-coder:7b" # コード補助。Q4 で ~4.7 GiB、3060 Ti 単体にも載る
      "qwen3:14b"        # 汎用チャット。Q4 で ~9 GiB、2 枚に分割して載る
      "nomic-embed-text" # 埋め込み / RAG 用。~0.3 GiB と軽い
    ];

    # 新しい nixpkgs にある services.ollama.syncModels (宣言外のモデルを
    # 削除する) は 25.05 にはまだありません。既定どおり、手で ollama pull した
    # モデルはそのまま残ります。
  };

  # GPU が使える状態になってから起動する。
  # nvidia-persistenced が上がっていればドライバは初期化済みです。
  systemd.services.ollama = {
    after = [ "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
  };

  ############################################################################
  # Open WebUI
  #
  # Ollama 自体は認証を一切持ちません。ブラウザから使う窓口はこちらに寄せ、
  # アカウント管理は Open WebUI 側で行います。
  ############################################################################
  services.open-webui = {
    enable = true;
    host = "0.0.0.0";
    port = ports.openWebui;
    openFirewall = false; # 下のファイアウォール設定でまとめて開けます

    environment = {
      OLLAMA_BASE_URL = "http://127.0.0.1:${toString ports.ollama}";

      # 初回アクセスで作った管理者アカウントが必須になる。
      # False にすると tailnet の誰でも素通りになります。
      WEBUI_AUTH = "True";

      # 外部へのテレメトリを止める。閉じたホストなので送っても意味がありません。
      ANONYMIZED_TELEMETRY = "False";
      DO_NOT_TRACK = "True";
      SCARF_NO_ANALYTICS = "True";

      # RAG の埋め込みもローカルの Ollama に寄せる。
      # 既定では HuggingFace から sentence-transformers を落としてきます。
      RAG_EMBEDDING_ENGINE = "ollama";
      RAG_EMBEDDING_MODEL = "nomic-embed-text";
    };
  };

  ############################################################################
  # 公開範囲
  #
  # tailscale0 からのみ。LAN には出しません。
  # 特に Ollama の API は無認証なので、LAN に晒すと同じネットワークの
  # 誰でもモデルの実行と削除ができます。
  #
  # Open WebUI (8080) はここでは開けません。到達経路は
  # modules/reverse-proxy.nix の Tailscale Serve (tailnet の 443 のルート) に
  # 一本化してあります。
  #
  # 一方 Ollama の 11434 は直接開けたままにしています。ollama CLI や
  # OLLAMA_HOST を使うクライアントはベース URL にパスを含められず、
  # https://<fqdn>/ollama/ では接続できないためです。tailnet 限定なので
  # 公開範囲は Serve 経由と変わりません。
  #
  # LAN からも叩く必要が出たら networking.firewall.allowedTCPPorts に
  # 足すことになりますが、その前に本当に必要か検討してください。
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    ports.ollama
  ];

  # ollama CLI をシステムに入れておく (ollama list / ps / pull 用)。
  # サーバと同じ CUDA 版を使い、バージョン差を出さないようにします。
  environment.systemPackages = [ config.services.ollama.package ];

  ############################################################################
  # 運用メモ
  #
  # 状態確認
  #   systemctl status ollama open-webui
  #   ollama list          # 手元のモデル
  #   ollama ps            # ロード中のモデルと GPU/CPU の配分
  #   journalctl -u ollama -b | grep "inference compute"
  #                        # 認識された GPU が 2 行出るか
  #
  # 2 枚構成が本当に速いかを測る
  #   1) 現状で計測
  #        curl -s http://127.0.0.1:11434/api/generate \
  #          -d '{"model":"qwen2.5-coder:7b","prompt":"数を1から50まで数えて","stream":false}' \
  #          | grep -o '"eval_count":[0-9]*\|"eval_duration":[0-9]*'
  #      tok/s = eval_count / (eval_duration / 1e9)
  #   2) このファイルの OLLAMA_SCHED_SPREAD を消し
  #      CUDA_VISIBLE_DEVICES = "1" にして rebuild、同じ計測
  #   3) 遅くならないなら 1 枚構成のままにする。
  #      Grafana の NVIDIA ダッシュボードで両カードが均等に回っているかも
  #      あわせて確認してください。
  #
  # モデル置き場
  #   /var/lib/ollama/models は専用の ZFS データセット
  #   (rpool/var/lib/ollama → /var/lib/private/ollama にマウント,
  #    recordsize=1M, compression=off)。
  #   スナップショットも syncoid のバックアップも対象外です。消えたら
  #   ollama pull で取り直します。使用量: zfs list rpool/var/lib/ollama
  #
  # Open WebUI の state
  #   DynamicUser=true なので実体は /var/lib/private/open-webui です。
  #   /var/lib/open-webui はそこへの symlink になります
  #   (VictoriaMetrics と同じ。disko/default.nix のコメント参照)。
  #   会話履歴とユーザー DB が入るので、こちらは rpool/var/lib の
  #   スナップショットと syncoid の対象に含まれます。
  #
  # メトリクス
  #   Ollama は Prometheus のエンドポイントを持ちません。
  #   GPU は nvidia-gpu-exporter (9835)、プロセスとユニットの状態は
  #   node exporter で見えるので、scrape job は追加していません。
  ############################################################################
}
