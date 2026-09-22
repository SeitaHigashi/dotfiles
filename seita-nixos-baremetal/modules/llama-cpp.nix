{ config, lib, pkgs, ... }:

##############################################################################
# llama.cpp (PrismML フォーク) のルーターサーバー。Ollama の置き換え候補。
#
# 何のために入れるか:
#   ~/bonsai-workspaces で seita が検証してきた Bonsai-2 27B (三値量子化) を
#   常駐サービスにする。前段に llama-swap を置き、リクエストの "model"
#   フィールドを見てモデルごとの llama-server を子プロセスとして起動・
#   切り替えします (= ollama serve 相当)。
#   OpenAI 互換 API (/v1/chat/completions, /v1/embeddings, /v1/models)。
#
#   ★ フォーク自身のルーターモード (--models-preset) は使っていません ★
#     追い出しが枠数ベースの LRU しか無く、このホストの VRAM 制約を
#     表現できないためです。経緯は swapConfig のコメントを参照。
#
# ★ 既定では起動しません (wantedBy = [])。★
#   VRAM は 2 枚合計で約 13.6 GiB しかなく、ollama が OpenViking 用に
#   常駐すると約 4.7 GiB を占めます。その状態では Bonsai は 4K context しか
#   載りません。つまり両方を「定義」はできても「同時に動かす」意味はない、
#   というのが移行作業側 (bonsai-workspaces) の実測結論です。
#
#   VRAM を食っているのは ollama だけではありません。3060 Ti (8192 MiB) には
#   ollama とは無関係に常駐しているものがあります (2026-09-21 実測):
#     fukurou-server (modules/fukurou.nix)  478 MiB
#     ComfyUI        (modules/comfyui.nix)  130 MiB
#   つまり ollama を止めても 3060 Ti の空きは約 6.8-7.1 GiB で、8 GiB
#   丸ごとにはなりません。
#
#   ★ ただしこれは「見落とされていた目減り」ではありません ★
#     移行作業側の実測値 (33.6 tok/s、32768 OK / 36864 OOM といった上限) は
#     すべて、この 2 つが常駐した状態のカードに対して取られたものです。
#     同日に fukurou / ComfyUI を載せたまま [bonsai] をロードし直して
#     33.8 tok/s と再現確認済み (ロード後 7330/8192 MiB)。
#     したがってプリセットの数値をこの 2 つのために割り引く必要はありません。
#     逆に言えば、fukurou や ComfyUI を止めても余裕が増えるだけで、
#     プリセットを変更する理由にはなりません。
#   したがって当面は手動起動:
#     sudo systemctl start llama-cpp
#   ollama から本当に切り替えるときに、この wantedBy と modules/ollama.nix の
#   services.ollama.enable、modules/alerting.nix の死活監視 (後述) を
#   まとめて反転させてください。
#
# なぜ ollama ではなくこれなのか (そもそもの動機):
#   Bonsai-2 の PTQ1_0 / PQ2_0 という三値/1bit パッキングを復号できるのは
#   PrismML のフォークだけで、本家 llama.cpp にも ollama にもカーネルが
#   ありません。ollama のモデル blob も独自形式なので相互に使い回せません。
#
# ビルド方式 — ここは設計判断なので経緯を残します:
#   bonsai-workspaces 側 (~/bonsai-workspaces) は独立した flake で、
#   packages.llama-cpp-prism-cuda を持っています。素直に考えると
#     inputs.bonsai.url = "path:/home/seita/bonsai-workspaces";
#   と flake input にするところですが、これは採れません。
#   ~/bonsai-workspaces は git リポジトリではなく、`path:` の flake input は
#   ディレクトリツリーを丸ごと nix store にコピーします。models/ に GGUF が
#   27 GiB あるため、eval のたびに store が 27 GiB ずつ太ります。
#   (git リポジトリなら追跡ファイルだけが対象になるので事情が変わります。)
#
#   そこで、フォークの「ソースの取得」だけをこのモジュールに持ち込み、
#   派生は nixpkgs の llama-cpp を override して組み立てています。
#   rev は bonsai-workspaces/flake.lock に固定されているものと同一:
#     github:PrismML-Eng/llama.cpp rev 9a9394a (branch prism)
#   フォークを更新したいときは bonsai-workspaces 側の flake.lock を上げてから、
#   下の prismRev / prismHash を同じ値に合わせてください (正は向こう側)。
#
#   ★ 初回の switch はビルドが長い ★
#     CUDA 付き llama.cpp のソースビルドで、バイナリキャッシュは効きません
#     (フォークなので当然 hydra にありません)。~/bonsai-workspaces で
#     `nix build .#llama-cpp-prism-cuda` 済みのものが store にありますが、
#     あちらは向こうの nixpkgs ピン、こちらは modules/unstable.nix の
#     nixpkgs-unstable ピンでビルドするため、store パスは一致せず再ビルドに
#     なります。switch の前に単体でビルドを通しておくのが安全です:
#       nix build --no-link \
#         .#nixosConfigurations.seita-nixos-baremetal.config.system.build.toplevel
#
#   代案 (今は採っていない): modules/fukurou.nix / modules/comfyui.nix と同じ
#   「Nix はプロセス起動だけ面倒を見る」方式で、ExecStart に
#   ~/bonsai-workspaces/result-llama/bin/llama-server を直接書く。ビルド時間は
#   ゼロですが、システム構成が git 管理外の手動 `nix build` の結果に依存し、
#   result シンボリックリンクを消すと GC でサービスが壊れます。常駐させる
#   以上は宣言的な今の形を選びました。
#
# CUDA について:
#   cudaSupport は nixpkgs 全体ではなく llama-cpp の override で名指し指定
#   します (CLAUDE.md の「nixpkgs.config.cudaSupport = true は設定しない」に
#   従う — 全体に付けると nixpkgs 丸ごと再ビルドになります)。CUDA ランタイムの
#   unfree 許可は modules/unfree.nix の "cuda" / "libcu" 接頭辞で既に通って
#   いるので、あちらへの追記は不要です (確認済み)。
#
# ★ CUDA_DEVICE_ORDER = PCI_BUS_ID を必ず明示する ★
#   GPU の割り当ては swapConfig のモデルごとの CUDA_VISIBLE_DEVICES で
#   行っており、その番号は PCI バス順です。このホストの実測:
#     index 0 = GTX 1660 SUPER (00000000:04:00.0, 6144 MiB, sm_75, テンソルコア無し)
#     index 1 = RTX 3060 Ti    (00000000:06:00.0, 8192 MiB, sm_86)
#
#   ★ 2026-09-22 以前はここが FASTEST_FIRST で、「PCI_BUS_ID にしては
#     いけない」と書いてありました。逆転しています ★
#     当時は models.ini が device = CUDA0 / CUDA1 という「速い順」前提の
#     名前でカードを指していたため、PCI 順にすると 27B が 1660 SUPER に
#     行って OOM しました。llama-swap 方式ではデバイス名で指さず、
#     プロセスごとに CUDA_VISIBLE_DEVICES でカードを見せる/見せないので、
#     ヒューリスティック (どちらが「速い」か) に依存しない PCI 順のほうが
#     安定します。GPU を載せ替えたら上の対応表を実測し直すこと。
#
#   modules/ollama.nix:117-122 も CUDA_DEVICE_ORDER = "PCI_BUS_ID" です。
#   環境変数はユニットごとなので互いに影響しません。
#
# モデルの置き場:
#   /home/seita/bonsai-workspaces/models (27 GiB) をそのまま使い、
#   disko にデータセットを足していません。理由は 3 つ:
#     1. /home は既に dpool/home、つまり HDD ミラー上にあります。冗長性の
#        観点では新設する必要がありません。
#     2. 稼働中システムへのデータセット追加は手順を誤ると emergency mode に
#        落ちます (CLAUDE.md の disko の項、2026-08-25 の openviking の事例)。
#        得るものに対してリスクが見合いません。
#     3. User=seita で動かすので DynamicUser の /var/lib/private 問題
#        (disko/default.nix:253-256 の EBUSY) がそもそも発生しません。
#   ただし dpool/home は auto-snapshot の対象なので、27 GiB の GGUF が
#   スナップショットに乗ります。GGUF は再ダウンロードできるので保持する
#   価値は薄く、置き場を専用データセット (recordsize=1M / compression=off /
#   auto-snapshot=false、var/lib/ollama と同じ設定) に移すのは将来の改善候補です。
#   移すときは上記 2 の手順 (switch 前に手で zfs create) を必ず踏むこと。
#
# モデルの取得は宣言しません。合計 27 GiB を fetchurl で nix store に入れる
# 選択肢は無く、ollama の手動 pull と同じ扱いにします:
#   ~/bonsai-workspaces/scripts/download-model.sh
#
##############################################################################
# ★★ ollama から切り替えるときの手順 ★★
#
# Open WebUI から ollama への依存は 3 本あります。3 本とも移さないと、
# 一部だけ静かに壊れます (エラーにならず「動いているように見える」のが
# 厄介なところです)。
#
#   (1) OLLAMA_BASE_URL              — modules/ollama.nix:291
#   (2) RAG_EMBEDDING_ENGINE = "ollama" + RAG_EMBEDDING_MODEL =
#       "nomic-embed-text" — modules/ollama.nix:305-306
#       RAG (ドキュメント添付) の埋め込みが ollama の nomic-embed-text を
#       直接呼びます。移行先は [embedding-nomic] プリセットです
#       ([embedding] ではありません — あちらは Qwen3 で OpenViking 用)。
#
#       ★ 再インデックスは「たぶん不要、ただし未証明」★
#         同じ nomic-embed-text v1.5 系で、次元数も一致します
#         (実機のルーターで測定: embedding-nomic = 768、embedding = 2560。
#          ollama の nomic-embed-text タグも v1.5 の 768 次元)。
#         ただし ollama の実装と llama.cpp の実装でベクトルそのものを
#         突き合わせた検証はしていません。pooling や正規化の細部が違えば、
#         ollama が作った既存インデックスに対する検索精度が落ちる可能性は
#         残ります。確実を取るなら切り替え後に Knowledge を再インデックス
#         してください (コストは時間だけです)。
#
#         2026-09-21 の決定: 再インデックスは方針としては行うが、今回の
#         切り替えには含めない (先送り)。したがってこのモジュールも
#         「再インデックス済み」を前提にしていません。切り替え時点の RAG は
#         embedding-nomic に向けて様子を見るか、当面 ollama に向けたまま
#         残すかのどちらでも成立します。
#         ★ [embedding] (Qwen3, 2560 次元) を指した場合は、次元が違うので
#           再インデックスが「必ず」要ります ★
#   (3) Open WebUI の Pipe 関数 (Admin Panel → Functions)
#       ★ これはリポジトリから配備できません ★ Web UI で手編集されたもので、
#       どの diff にも現れません。__task__ 呼び出し (title_generation /
#       follow_up_generation) が http://127.0.0.1:11434/api/chat を直接
#       叩いており、model は gemma4:12b、独自 Valve の task_num_ctx = 163840。
#       詳細は ~/seita-n8n-workflows/docs/integrations.md:599-621、
#       背景は同 docs/gotchas.md:535-543。
#
# ★ 環境変数を書き換えるだけでは (1) と (2) は効きません ★
#   Open WebUI の PersistentConfig の仕様です。実機の 0.11.3 で確認:
#     config.py:3237  ENABLE_PERSISTENT_CONFIG は既定 True
#     config.py:2833- DEFAULT_CONFIG に 'ollama.base_urls' /
#                     'openai.api_base_urls' / 'rag.embedding_engine' がある
#   ここに載っている設定は「初回起動時に環境変数を DB に取り込み、以降は
#   DB 側が勝つ」挙動になります。
#
#   ★ modules/ollama.nix:291 の OLLAMA_BASE_URL はこのホストでは既に
#     無効です ★ DB が出来た後なので seed として残っているだけで、実際の
#     接続先は Admin Panel の値です。「設定されているのだから効いている」と
#     読まないでください。また、ここを書き換えても接続先は変わりません。
#     承知のうえで残してあるので、"修正" しないこと。
#
#   2026-09-21 の決定: 切り替えは Admin Panel → Settings → Connections で
#   手作業で行います。ENABLE_PERSISTENT_CONFIG = "False" は足しません
#   (Open WebUI の接続設定は DB / UI 側の持ち物のままにする、という判断)。
#   つまり Open WebUI の接続先は git の管理外です — このモジュールにも
#   modules/ollama.nix にも現れないので、迷ったら UI を見てください。
#
# API の形が変わる点 (llama.cpp は OpenAI 互換であって Ollama 互換ではない):
#   Open WebUI 側は OLLAMA_BASE_URL ではなく
#     OPENAI_API_BASE_URL = "http://127.0.0.1:8888/v1"
#     OPENAI_API_KEY      = 何か非空のダミー文字列
#   を使います (config.py:317-345 に両方あることを実機で確認済み)。
#   ollama 側を完全に止めるなら ENABLE_OLLAMA_API = "False" も。
#
#   Pipe のペイロードも Ollama 形式から OpenAI 形式に直す必要があります。
#   移行作業側と n8n 側が実測で詰めた結果:
#     - モデル名は ollama のタグではなくプリセット名。
#       gemma4:12b -> gemma4 (16K) または gemma4-32k (32K)。
#     - options.temperature -> トップレベルの temperature。
#     - options.num_ctx に相当するものはありません。context はプリセット
#       ごとにサーバー起動時に固定されます (だから 32K 版を別プリセットに
#       しています)。task_num_ctx = 163840 は行き場が無いので、
#       gemma4-32k を指す形に読み替えてください。
#     - think は不要。llama.cpp は推論部分を常に reasoning_content として
#       別に返します。
#     - ★ 構造化出力の罠 ★
#         {"type":"json_schema","schema":{...}}
#           -> HTTP 200 で通りますが schema は黙って無視されます
#              (3/3 で無関係なキーが返った、との実測)
#         {"type":"json_schema","json_schema":{"name":"x","schema":{...}}}
#           -> 正しい形 (3/3 成功)
#     - ★ content が空文字でも成功に見えます ★ max_tokens を reasoning が
#       食い切ると content = "" で 200 が返ります。呼び出し側で空判定を。
#
# 切り替え時に一緒に反転させるもの:
#   - このモジュールの wantedBy = [] -> [ "multi-user.target" ]
#   - modules/ollama.nix の services.ollama.enable
#   - modules/alerting.nix の service-inactive ルールの name=~
#     (llama-cpp.service を足して ollama.service を外す)
#   - modules/resource-priority.nix の ollama の MemoryHigh 12G を
#     llama-cpp 側の予算に回す
#   - OpenViking (modules/openviking.nix) も ollama を使っています。
#     こちらは移行作業側が別途ブリーフする予定 — 勝手に触らないこと。
##############################################################################

# 待ち受け:
#   127.0.0.1:8888。8080 は Open WebUI (modules/ollama.nix の ports.openWebui)
#   なので使えません。tailnet / LAN には出していません。外から使う段階に
#   なったら modules/reverse-proxy.nix の routes に足してください
#   (ただし Ollama と同じ理由でサブパス配下に置くとクライアントが困る可能性が
#    あります — OpenAI 互換のベース URL はパスを含められるので、Ollama ほど
#    深刻ではないはずです)。
##############################################################################

let
  m = import ../machine.nix;

  port = 8888;

  # モデルとルーターの作業ディレクトリ。bonsai-workspaces のチェックアウト。
  workDir = "/home/${m.userName}/bonsai-workspaces";
  modelsDir = "${workDir}/models";

  ##########################################################################
  # PrismML フォークのソース。rev は bonsai-workspaces/flake.lock と同一。
  # hash は同 lock の narHash をそのまま使っています (type = "github" の
  # narHash は展開後ツリーの NAR ハッシュで、fetchFromGitHub のものと一致します)。
  # 食い違ったら nix が期待値を出してくれるので、それに差し替えてください。
  ##########################################################################
  prismRev = "9a9394a895b96003ca842a6041cb28ac49a108f7";
  prismHash = "sha256-KDecY+v9S/193mLGse5EsJPugZR1wxWzOlOU7GuMd5Y=";

  prismSrc = pkgs.fetchFromGitHub {
    owner = "PrismML-Eng";
    repo = "llama.cpp";
    rev = prismRev;
    hash = prismHash;
  };

  # nixpkgs の llama-cpp をフォークのソースで差し替える。
  # patches = [] にしているのは、nixpkgs 側のパッチが本家の行番号を前提に
  # しておりフォークには当たらないためです (bonsai-workspaces 側と同じ判断)。
  llamaCppPrism =
    (pkgs.unstable.llama-cpp.override { cudaSupport = true; }).overrideAttrs
      (old: {
        pname = "llama-cpp-prism";
        version = builtins.substring 0 7 prismRev;
        src = prismSrc;
        patches = [ ];
        doCheck = false;

        ######################################################################
        # CUDA のターゲットアーキテクチャをこのホストの 2 枚だけに絞る。
        #   75 = GTX 1660 SUPER (TU116) / 86 = RTX 3060 Ti (GA104)
        #
        # nixpkgs の既定は 75;80;86;89;90;100;103;120;121 の 9 つです
        # (実機で確認)。どれも正しく動きますが、CUDA のコード生成はこの
        # ビルドの大半を占める処理で、4C/8T の Ryzen 3 3300X では
        # 9 アーキテクチャ分をビルドする時間がそのまま初回 switch の待ち時間に
        # なります。2 つに絞ったときの libggml-cuda.so が約 98 MB なのに対し、
        # 9 つだとその数倍です。
        #
        # nixpkgs.config.cudaCapabilities は nixpkgs 全体の設定で、指定には
        # nixpkgs の再 import が要ります。ここではその必要はありません —
        # 実体は cmake のフラグ 1 つなので、cmakeFlags を差し替えるだけで済みます。
        #
        # GPU を載せ替えたらこの値の更新が要ります。合わない SM の GPU では
        # 起動時に CUDA エラーになります (対応表は NVIDIA の CUDA GPUs 参照)。
        ######################################################################
        cmakeFlags =
          (builtins.filter
            (f: !(lib.hasPrefix "-DCMAKE_CUDA_ARCHITECTURES" f))
            old.cmakeFlags)
          ++ [ "-DCMAKE_CUDA_ARCHITECTURES:STRING=75;86" ];
      });

  ##########################################################################
  # llama-swap の設定 YAML。
  #
  # ★ 2026-09-22: PrismML フォーク自身のルーターモード (--models-preset +
  #   --models-max) から llama-swap に置き換えました ★
  #
  #   理由は 1 つで、フォークのルーターの追い出しが「枠数ベースの LRU」
  #   だけだったことです。VRAM もデバイスも見ていないため:
  #     - CUDA1 が空いていても CUDA0 の [bonsai] が追い出される
  #     - CPU 実行の [embedding] が LRU で選ばれると、追い出しても VRAM が
  #       1 バイトも空かず、結局 OOM する (実測。これが --models-max 1 まで
  #       下げる羽目になった直接の原因)
  #   どちらも「どのモデルとどのモデルが同居できるか」を表現する手段が
  #   無いことに起因していて、パラメータの調整では消せません。
  #
  #   llama-swap (mostlygeek/llama-swap、Go、OpenAI/Anthropic 互換の前段
  #   プロキシ) はモデルごとに llama-server を子プロセスとして起動し、
  #   同居の可否を設定として書けます。フォークのバイナリをそのまま
  #   cmd に書けるので、PrismML 依存はまったく損ないません。
  #
  #   ★ routing engine は matrix を選んでいます ★
  #     もう一方の group エンジン (swap / exclusive / persistent) でも
  #     「embedding は bonsai を追い出さない」までは表現できますが、
  #     このホストの制約は本質的に「どの組み合わせなら VRAM に載るか」
  #     であって、グループの階層ではありません。matrix は載る組み合わせを
  #     sets に列挙し、evict_costs の小さいものから追い出すソルバなので、
  #     制約をそのまま書けます。
  #
  # ★ np = 1 は消さないこと ★
  #   llama-server の既定は並列スロット 4 で、再帰状態のキャッシュを
  #   スロットごとに確保します。llama-cli と同じ context でも VRAM 消費が
  #   数倍になり、27B はこのホストで OOM します。
  #   埋め込みモデルだけは例外で、スロットごとに増える再帰状態が無いため
  #   既定の 4 のままにしてあります (同時リクエストに有利)。
  #
  # 数値の根拠 (tok/s、context の上限など) は移行作業側の実測です。
  # 変更するときは ~/bonsai-workspaces/models.ini 側のコメントも見てください。
  #
  # ------------------------------------------------------------------------
  # ★ GPU の割り当ては CUDA_VISIBLE_DEVICES で、モデルごとに行います ★
  #
  #   以前は models.ini の device = CUDA0 / CUDA1 で指定していましたが、
  #   この方式には穴があります。ggml は --device で「使わない」と指定した
  #   デバイスにも、見えている限り CUDA コンテキストを作る (数百 MiB) ため、
  #   [bonsai] が CUDA0 を 410 MiB しか残さない状態では、CPU 実行のはずの
  #   埋め込みプロセスですら CUDA0 を踏んで落ちる可能性があります。
  #   llama-swap はモデルごとに別プロセスなので、env でカードそのものを
  #   見えなくできます。これは 1 プロセスのルーターには原理的にできません。
  #
  #   ★ CUDA_DEVICE_ORDER は PCI_BUS_ID にしました (以前は FASTEST_FIRST) ★
  #     以前 PCI_BUS_ID を禁じていたのは、models.ini が CUDA0/CUDA1 という
  #     「速い順」前提の名前でカードを指していたからです。その名前を使うのを
  #     やめた今は逆で、PCI バス番号のほうがヒューリスティックに依存しない
  #     ぶん安定します。このホストの実測 (nvidia-smi --query-gpu=pci.bus_id):
  #       index 0 = GTX 1660 SUPER (00000000:04:00.0, 6144 MiB, sm_75)
  #       index 1 = RTX 3060 Ti    (00000000:06:00.0, 8192 MiB, sm_86)
  #     したがって CUDA_VISIBLE_DEVICES は
  #       "1"   = 3060 Ti のみ    (bonsai 系)
  #       "0,1" = 2 枚とも        (gemma4 系)
  #       ""    = GPU を見せない  (埋め込み。CUDA を一切初期化しない)
  #     GPU を載せ替えたらこの対応表を実測し直すこと。
  #
  #   ★ 1660 SUPER には fukurou (whisper.cpp) が約 479 MiB 常駐しています ★
  #     modules/fukurou.nix がこのカードにピン留めしているためです
  #     (2026-09-22 実測、6144 MiB 中 489 MiB 使用)。下の数値はこれを
  #     含んだ状態で取っています。
  # ------------------------------------------------------------------------
  ##########################################################################
  bonsaiModel = "${modelsDir}/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-PTQ1_0.gguf";
  gemmaDir = "${modelsDir}/gemma-4-12B-it-GGUF";

  swapConfig = pkgs.writeText "llama-swap.yaml" ''
    # このファイルは Nix が生成しています。直接編集しないこと
    # (modules/llama-cpp.nix が正)。

    # 子プロセスの llama-server が使うポートの開始番号。8888 (llama-swap 本体)
    # や 8080 (Open WebUI)、5678 (n8n) と衝突しない帯を選んでいます。
    startPort: 18900

    # 27B のロードには時間がかかります。既定の 500 秒で足りていますが、
    # 明示しておきます。
    healthCheckTimeout: 500
    logLevel: info

    # 0 = 自動アンロードしない。このホストでは「空いたから降ろす」より
    # 「必要になったら matrix が追い出す」ほうが素直なので、TTL は使いません。
    globalTTL: 0

    macros:
      # フォークの llama-server。PORT は llama-swap がモデルごとに割り当てる
      # 変数で、Nix の補間ではありません (このファイルでは二重シングルクォートで
      # エスケープしています)。
      "server": "${llamaCppPrism}/bin/llama-server --port ''${PORT}"

    models:
      # ----------------------------------------------------------------
      # Bonsai 2 / PTQ1_0 を 3060 Ti 単体で。このホストでの最良構成の実測値:
      # 33.6-33.8 tok/s。1660 SUPER に 1 層も載せないことが生成で 1.3-1.5 倍、
      # プロンプト処理で 2.5-3.7 倍に効きます (1660 SUPER にテンソルコアが
      # 無いため)。
      #
      # ★ c = 81920 は KV を q4_0 にしたときの 3060 Ti 単体の上限です ★
      #   2026-09-22 実測 (カードを空にした状態、ctk = ctv = q4_0、np = 1、
      #   ngl = 99):
      #     32768 OK (6674 MiB)   65536 OK (7410 MiB)
      #     81920 OK (7778 MiB)   90112 NG   98304 NG
      #   NG 側の失敗は OOM ではなく
      #     llama_init_from_model: failed to initialize the context:
      #     failed to allocate compute pp buffers
      #   です (計算バッファが取れない)。ロード後の空きは 81920 で約 410 MiB。
      #
      #   生成速度は 32.75 tok/s (80K、200 トークン生成の実測)。q8_0 / 32768 の
      #   33.4-33.8 tok/s からほぼ落ちていません — KV 量子化は生成の律速では
      #   ないためです。代償は KV の精度 (q8_0 → q4_0) だけです。
      #
      #   ★ 残り 410 MiB しかないことは、llama-swap 方式では問題になりません ★
      #     同居しうるのは CUDA を一切見ない埋め込みプロセスだけだからです
      #     (下の embedding / embedding-nomic の CUDA_VISIBLE_DEVICES="")。
      #     3060 Ti を使う他のモデルは matrix が必ず bonsai を降ろしてから
      #     起動します。
      # ----------------------------------------------------------------
      "bonsai":
        name: "Bonsai 2 27B (80K)"
        env:
          - "CUDA_VISIBLE_DEVICES=1"
        cmd: |
          ''${server}
          --model ${bonsaiModel}
          --jinja
          -np 1
          -ngl 99
          -c 81920
          --cache-type-k q4_0
          --cache-type-v q4_0
          --temp 0.5
          --top-p 0.85
          --top-k 20

      # 同じ重み + vision projector (+600 MB)。その分 context が 8192 に落ちます。
      "bonsai-vision":
        name: "Bonsai 2 27B (vision)"
        env:
          - "CUDA_VISIBLE_DEVICES=1"
        cmd: |
          ''${server}
          --model ${bonsaiModel}
          --mmproj ${modelsDir}/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
          --jinja
          -np 1
          -ngl 99
          -c 8192
          --cache-type-k q8_0
          --cache-type-v q8_0
          --temp 0.5
          --top-p 0.85
          --top-k 20

      # ----------------------------------------------------------------
      # Gemma 4 12B (ggml-org の標準 GGUF。ollama の blob は独自形式で
      # 互換レイヤが要るため、ここからは再利用できません)。
      #
      # ★ 2 枚必要です。1 枚には収まりません ★
      #   2026-09-22 実測。重みが 7.22 GB (6.72 GiB) あり、1660 SUPER の
      #   6144 MiB には入りません。-ngl 99 も -ngl 36 も -ngl 30 も
      #   cudaMalloc failed で落ちます。ngl を指定しなければフォークの
      #   common_fit_params が空き VRAM に合わせて自動で減らしてくれますが、
      #   その結果は 20/49 層だけ GPU (CUDA0 3343 MiB / CPU 4546 MiB) で、
      #     生成 8.13 tok/s、プロンプト処理 14.42 tok/s
      #   でした。n8n の Task Partner Brain は 13 個のツールスキーマを毎回
      #   送るので、プロンプト処理 14 tok/s は実用になりません。
      #   したがって gemma4 は 2 枚使う前提のままにし、起動時に bonsai を
      #   降ろす (下の matrix を参照) 方針にしています。
      # ----------------------------------------------------------------
      "gemma4":
        name: "Gemma 4 12B (16K)"
        env:
          - "CUDA_VISIBLE_DEVICES=0,1"
        cmd: |
          ''${server}
          --model ${gemmaDir}/gemma-4-12B-it-Q4_0.gguf
          --mmproj ${gemmaDir}/mmproj-gemma-4-12B-it-Q8_0.gguf
          --jinja
          -np 1
          -ngl 99
          -c 16384
          --split-mode layer

      # 同じ Gemma 4 を 32K context で。KV を q8_0 に量子化してその分を捻出。
      # 用途は n8n の Task Partner Brain (13 個のツールスキーマ + 8 ターンの
      # バッファウィンドウ + システムプロンプト) と、Open WebUI の Pipe
      # (title_generation / follow_up_generation) で 16K では足りない場合。
      #
      # 32768 は 2026-08-11 以前にそのワークフローが実際に動いていた値です。
      # その後 163840 に引き上げられたのは、num_ctx を変えるたびに ollama が
      # モデルを再ロードするのを止めるためだけの措置でした — llama.cpp には
      # 無い問題なので、本来の 32768 に戻してあります。
      "gemma4-32k":
        name: "Gemma 4 12B (32K)"
        env:
          - "CUDA_VISIBLE_DEVICES=0,1"
        cmd: |
          ''${server}
          --model ${gemmaDir}/gemma-4-12B-it-Q4_0.gguf
          --mmproj ${gemmaDir}/mmproj-gemma-4-12B-it-Q8_0.gguf
          --jinja
          -np 1
          -ngl 99
          -c 32768
          --cache-type-k q8_0
          --cache-type-v q8_0
          --split-mode layer

      # ----------------------------------------------------------------
      # 埋め込みは 2 つとも CPU 実行です。
      #
      # ★ CUDA_VISIBLE_DEVICES="" が要点です ★
      #   -ngl 0 だけでは足りません。ggml は見えているデバイスに CUDA
      #   コンテキストを作るので、bonsai が 410 MiB しか残していない 3060 Ti を
      #   踏みます。カードごと見せないことで、bonsai と完全に無関係になります。
      #   これが「embedding が呼ばれても bonsai が落ちない」ことの実体です
      #   (matrix の sets だけでなく、物理的にも干渉しません)。
      #
      #   CPU 実行の実測は warm で約 66 ms/リクエスト。1660 SUPER に戻せば
      #   速くはなりますが、そのカードは gemma4 と fukurou が使うので、
      #   「常に居られる」ことを優先して CPU のままにしています。
      # ----------------------------------------------------------------

      # Qwen3-Embedding-4B、2560 次元 (実機のルーターで測定済み)。OpenViking 用。
      "embedding":
        name: "Qwen3 Embedding 4B"
        env:
          - "CUDA_VISIBLE_DEVICES="
        cmd: |
          ''${server}
          --model ${modelsDir}/Qwen3-Embedding-4B-GGUF/Qwen3-Embedding-4B-Q4_K_M.gguf
          --embeddings
          --pooling last
          -ngl 0
          -c 8192

      # nomic-embed-text v1.5、768 次元。Open WebUI の RAG が既にこのモデルで
      # インデックスを作っているため (modules/ollama.nix:306 の
      # RAG_EMBEDDING_MODEL = "nomic-embed-text")、切り替えで Knowledge の
      # 作り直しを迫られないように残してあります。Qwen3 の "embedding" は
      # 別モデルかつ別次元なので、そちらを指すと作り直しが必要になります。
      "embedding-nomic":
        name: "nomic-embed-text v1.5"
        env:
          - "CUDA_VISIBLE_DEVICES="
        cmd: |
          ''${server}
          --model ${modelsDir}/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q8_0.gguf
          --embeddings
          --pooling mean
          -ngl 0
          -c 8192

    # ----------------------------------------------------------------------
    # ★ ここが「CUDA0 は bonsai 専用」を保証している箇所です ★
    #
    # matrix は「同時に走ってよい組み合わせ」を sets に列挙します。
    # リクエストが来ると、そのモデルを含む set のうち、追い出す羽目になる
    # 実行中モデルの evict_costs 合計が最小のものを選びます。
    # set の部分集合も許可されるので、下の 2 本だけで足ります。
    #
    #   generation: bonsai (または bonsai-vision) + 埋め込み 2 つ
    #   heavy:      gemma4 (または gemma4-32k)   + 埋め込み 2 つ
    #
    # 埋め込みは両方の set に入っているので、embedding が呼ばれても
    # 「bonsai + embedding」は generation の部分集合として成立し、
    # ★ bonsai は降りません ★。これが当初の LRU 方式との決定的な差です。
    #
    # 逆に gemma4 が呼ばれたときは、bonsai を含む set が存在しないので
    # bonsai が降ります。これは VRAM の制約 (上の gemma4 のコメント参照) で
    # あって設定の都合ではなく、避ける方法がありません。evict_costs で
    # bonsai を高くしてあるのは、選択の余地があるときに bonsai を残すためです。
    #
    # bonsai と bonsai-vision が同じ set の別の枝にあるのは、どちらも
    # 3060 Ti を占有するため同居できないからです。
    # ----------------------------------------------------------------------
    routing:
      router:
        use: matrix
        settings:
          matrix:
            evict_costs:
              # 27B + 80K の KV。ロードが重いので最後まで残す。
              bonsai: 50
              bonsai-vision: 50
              gemma4: 10
              gemma4-32k: 10
              # 埋め込みは CPU で軽く、そもそも追い出す理由が無い。
              embedding: 1
              embedding-nomic: 1
            sets:
              generation: "(bonsai | bonsai-vision) & embedding & embedding-nomic"
              heavy: "(gemma4 | gemma4-32k) & embedding & embedding-nomic"
  '';
in
{
  ############################################################################
  # environment.systemPackages にはあえて入れていません。
  #
  # このパッケージは llama-server / llama-cli / llama-bench のほかに、
  # ずばり `llama` という名前のバイナリを含みます。システム全体の PATH で
  # 主張するには一般的すぎる名前で、将来 PATH 上の別のものと衝突します。
  # サービスは ExecStart で store パスを直接指しているので、PATH は不要です。
  #
  # 対話的に叩きたいときは bonsai-workspaces の flake を使ってください:
  #   cd ~/bonsai-workspaces && nix develop        # llama-cli / llama-bench 等
  #   nix run ~/bonsai-workspaces#bench -- ...
  ############################################################################

  systemd.services.llama-cpp = {
    description = "llama-swap + llama.cpp (PrismML fork) — OpenAI-compatible, multi-model";

    # ★ 自動起動しません ★ 上の冒頭コメント参照。ollama と VRAM を取り合う
    # ため、切り替えを決めるまでは手動 (systemctl start llama-cpp) です。
    wantedBy = [ ];

    # GPU が使える状態になってから。modules/ollama.nix:215-218 と同じ理由で、
    # nvidia-persistenced が上がっていればドライバは初期化済みです。
    after = [ "nvidia-persistenced.service" "network.target" ];
    wants = [ "nvidia-persistenced.service" ];

    environment = {
      # ★ PCI_BUS_ID です (2026-09-22 に FASTEST_FIRST から変更) ★
      #   swapConfig の CUDA_VISIBLE_DEVICES は PCI バス順のインデックスで
      #   書かれています (0 = 1660 SUPER / 1 = 3060 Ti)。理由と実測は
      #   swapConfig 直前の長いコメントを参照。llama-swap 本体は GPU を
      #   使いませんが、この環境変数は子プロセスの llama-server に継承されます。
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
    };

    # クラッシュループの抑止。5 分のうち 3 回失敗したら諦めます。
    #
    # ★ serviceConfig ではなくここ (トップレベルのオプション) に書くこと ★
    #   StartLimitBurst / StartLimitIntervalSec は [Service] ではなく [Unit]
    #   セクションのディレクティブです (systemd v229 で移動)。serviceConfig に
    #   書くと systemd が "Unknown key name ... in section 'Service', ignoring"
    #   として黙って捨てるため、抑止が一切効きません。NixOS のこれらの
    #   オプションは unitConfig 側に出力されます
    #   (nixos/lib/systemd-lib.nix)。ユニットは正常に動いてしまい、
    #   VRAM 不足で OOM する 27B が 10 秒ごとに永久に再起動し続ける、という
    #   目に見えない形で壊れるので注意。
    startLimitBurst = 3;
    startLimitIntervalSec = 300;

    serviceConfig = {
      # DynamicUser ではなく seita 本人。モデルが seita のホーム配下にあり、
      # 読み取り権限をそのまま使うためです (modules/fukurou.nix と同じ理由)。
      User = m.userName;
      Group = "users";
      WorkingDirectory = workDir;

      # llama-swap が前段。子プロセスの llama-server は swapConfig の cmd から
      # 起動されるので、ここには現れません。
      #
      # ★ --watch-config は付けていません ★ 設定は nix store 上の読み取り専用
      #   ファイルで、変更は必ず rebuild 経由だからです。rebuild すると
      #   ExecStart の store パスが変わり、systemd が再起動対象と判定します。
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.unstable.llama-swap}/bin/llama-swap"
        "--config ${swapConfig}"
        "--listen 127.0.0.1:${toString port}"
      ];

      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
