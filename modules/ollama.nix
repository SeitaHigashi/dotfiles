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
#     GPU 1  GT 1030         表示専任 (modules/desktop.nix)。推論には使わない
#     GPU 2  RTX 3060 Ti     8 GiB  sm_86  PCIe x8
#   合計 VRAM (0+2) 14 GiB (ollama から見える実効値は 13.3 GiB)。
#   GPU 番号は CUDA_DEVICE_ORDER=PCI_BUS_ID の並び (PCI bus 04/05/07 の順)。
#   2026-08-11 に GT1030 を bus 05 へ増設した際、PCI bus 07 の 3060 Ti が
#   index 1 から 2 へ繰り下がった (以前は 2 枚構成で index 1 = 3060 Ti)。
#   CPU は Ryzen 3 3300X (4C/8T)。RAM 46 GiB のうち ZFS ARC に 16 GiB、
#   Minecraft のヒープに 8 GiB を既に割り当てているため、CPU オフロードに
#   使える余地は 20 GiB 程度です。
#
#   **選定の基準はパラメータ数ではなく「総サイズが VRAM に収まるか」です。**
#   あふれた分は CPU に落ち、特にプロンプト処理が桁で遅くなります。
#   2026-08-02 に実測した値 (同一プロンプト、日本語の要約 + JSON 強制):
#
#     gemma4:12b   7.6GB  収まる    プロンプト 177.9 tok/s  生成 35.0 tok/s
#     qwen3:14b      9GB  収まる    プロンプト 130.6 tok/s  生成 35.0 tok/s
#     gemma4:26b    18GB  収まらない プロンプト  18.8 tok/s  生成 26.0 tok/s
#
#   gemma4:26b は MoE (アクティブ 4B) ですが、**アクティブ数が小さくても
#   総サイズが収まらなければ遅くなります**。長い入力を読ませる用途では
#   プロンプト処理の差がそのまま所要時間になるため致命的です。
#   (CPU only で動かすと逆に MoE が有利になり順位が入れ替わります。
#    GPU が効いているかを確認せずにモデルを選ばないこと。)
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

    # **これが無いと package の指定が無意味になります。**
    #   nixos/modules/services/misc/ollama.nix は ExecStart に cfg.package を
    #   そのまま使わず、
    #     ollamaPackage = cfg.package.override { inherit (cfg) acceleration; };
    #   と書き戻します。acceleration の既定値は null なので、ollama-cuda を
    #   渡しても override で CUDA 無効のビルドに差し替えられてしまいます。
    #   実機で踏みました: config.services.ollama.package は CUDA 版を返すのに
    #   ユニットの ExecStart は CPU 版を指しており、lib/ollama/ に
    #   libggml-cuda.so が無いため GPU が 1 枚も検出されず (inference compute が
    #   cpu だけ)、全推論が CPU に落ちていました。
    acceleration = "cuda";

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

      # 速い 3060 Ti (index 2) を先頭にして、層の割り当てで優先させる。
      # GT1030 (index 1, 表示専任) は含めない。
      # (この順序は ollama から見た GPU 番号にも影響します)
      CUDA_VISIBLE_DEVICES = "2,0";

      # 1 枚に収まるモデルでも敢えて 2 枚に分散させる。
      #
      # ★ これは「速くなる」設定ではありません ★
      #   1660 SUPER は PCIe x4 かつ FP16 テンソルコアを持たない TU116 です。
      #   層分割ではカード間転送と遅い側の演算が律速し、3060 Ti 単体より
      #   tok/s が落ちることがあります。7B クラスで遅いと感じたら、
      #   この行を消して CUDA_VISIBLE_DEVICES = "2" に切り戻してください
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
      "gemma4:12b"        # 汎用チャット
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

    ##########################################################################
    # unstable 追従。
    #
    # なぜ unstable か:
    #   25.05 の open-webui は 0.6.9 で、unstable は 0.11.0 です。
    #   Ollama 本体を unstable に寄せている以上、UI 側も同世代に
    #   揃えておかないと新しいモデルや API の扱いで齟齬が出ます。
    #   Python アプリでカーネル・カーネルモジュール・systemd・glibc の
    #   いずれにも関わらない「葉」なので、この差し替えは安全です。
    #
    # n8n と違い overlay は不要です。services.open-webui には package
    # オプションがあるため、ここで名指しするだけで済みます。
    #
    # ※ 0.11.0 は非フリーです。0.6.x の MIT から独自の
    #   Open WebUI License に変わりました。許可は modules/gpu.nix の
    #   allowUnfreePredicate に書いています (nixpkgs.config は 1 箇所
    #   からしか定義できないため、ここには書けません)。
    #
    # ※ NixOS モジュールは 25.05 のものを使い続けます。unstable 側の
    #   モジュールは DATA_DIR を "." から "${stateDir}/data" に変え、
    #   既存データを移す preStart を持っていますが、こちらはパッケージ
    #   だけを差し替えるのでその配置変更は適用されません。データは
    #   従来どおり StateDirectory の直下に置かれます。中途半端に
    #   unstable 側のモジュールを真似しないこと。
    #
    # ※ 0.6.9 からは alembic のリビジョンが 16 -> 55 に進みます。
    #   起動時に自動適用され、ダウングレードは想定されていません。
    #   パッケージを戻すだけでは切り戻せず、rpool/var/lib の
    #   スナップショットからのロールバックが要ります。
    ##########################################################################
    package = pkgs.unstable.open-webui;

    host = "0.0.0.0";
    port = ports.openWebui;
    openFirewall = false; # 下のファイアウォール設定でまとめて開けます

    environment = {
      ########################################################################
      # データとキャッシュの置き場を絶対パスにする
      #
      # ★ これが無いと 0.11.0 は起動できません ★
      #   25.05 のモジュールはこの 4 つを "." (相対パス) で渡しますが、
      #   open-webui は 0.6.18 以降これを正しく扱えません。実際に踏んだ症状は
      #   起動時の `sqlite3.OperationalError: no such table: config` で、
      #   alembic のマイグレーションは 55 個すべて成功しているのに、
      #   アプリ本体はそれとは別の空 DB を掴んでいる、という状態になります。
      #   (既存データがある場合は「アカウントを作成してください」と言われる
      #    形で現れます — nixpkgs issue #430433 と同じ)
      #
      #   nixpkgs では PR #431395 でモジュール側が絶対パスに直されましたが、
      #   25.05 には入っていません。ここは module の environment が
      #   `// cfg.environment` で後勝ちになるので、モジュールを差し替えずに
      #   上書きできます。値は unstable のモジュールと同じにしてあります。
      #
      #   stateDir は /var/lib/open-webui で、DynamicUser のため実体は
      #   /var/lib/private/open-webui です (symlink 経由で解決されます)。
      ########################################################################
      STATIC_DIR = "${config.services.open-webui.stateDir}/static";
      DATA_DIR = "${config.services.open-webui.stateDir}/data";
      HF_HOME = "${config.services.open-webui.stateDir}/hf_home";
      SENTENCE_TRANSFORMERS_HOME = "${config.services.open-webui.stateDir}/transformers_home";

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
  #      CUDA_VISIBLE_DEVICES = "2" にして rebuild、同じ計測
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
