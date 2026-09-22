{ config, lib, pkgs, ... }:

##############################################################################
# llama.cpp (PrismML フォーク) のルーターサーバー。Ollama の置き換え候補。
#
# 何のために入れるか:
#   ~/bonsai-workspaces で seita が検証してきた Bonsai-2 27B (三値量子化) を
#   常駐サービスにする。llama-server に -m を渡さず --models-preset だけを
#   渡すと「ルーター」として動き、リクエストの "model" フィールドを見て
#   モデルごとの子プロセスを必要に応じて起動する (= ollama serve 相当)。
#   OpenAI 互換 API (/v1/chat/completions, /v1/embeddings, /v1/models)。
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
# ★ CUDA_DEVICE_ORDER = FASTEST_FIRST を必ず明示する ★
#   models.ini はモデルを CUDA0 / CUDA1 というデバイス名で GPU に固定して
#   います。この番号は CUDA ランタイムの列挙順であって nvidia-smi の順とは
#   別物で、このホストでは両者が逆です:
#     nvidia-smi 0 = GTX 1660 SUPER (bus 04:00) = CUDA1 (sm_75, テンソルコア無し)
#     nvidia-smi 1 = RTX 3060 Ti    (bus 06:00) = CUDA0 (sm_86)
#   CUDA の既定は「速い順」(FASTEST_FIRST) なので、既定のままでも意図した
#   割り当てになりますが、環境によって変わりうるものを黙って前提にしないため
#   明示的に固定します。
#
#   ここで PCI_BUS_ID にしてはいけません。models.ini の CUDA0/CUDA1 が
#   そっくり入れ替わり、3060 Ti に載せるつもりの 27B が 5.7 GiB しかない
#   1660 SUPER に行って OOM します。
#
#   modules/ollama.nix:117-122 が CUDA_DEVICE_ORDER = "PCI_BUS_ID" を
#   設定していますが矛盾しません。環境変数はユニットごとなので互いに
#   影響せず、あちらは「PCI 順に固定したうえで CUDA_VISIBLE_DEVICES = "1,0"
#   で 3060 Ti を先頭に持ってくる」という別の組み立て方をしているだけです。
#   結果としてどちらも 3060 Ti 優先で、狙いは同じです。
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
  # プリセット INI。~/bonsai-workspaces/models.ini の内容を Nix 側に持ち込み、
  # モデルのパスだけ modelsDir から組み立てています
  # (modules/openviking.nix の ovConfTemplate と同じ方針)。
  #
  # ★ np = 1 は消さないこと ★
  #   llama-server の既定は並列スロット 4 で、再帰状態のキャッシュを
  #   スロットごとに確保します。llama-cli と同じ context でも VRAM 消費が
  #   数倍になり、27B はこのホストで OOM します。
  #
  # 数値の根拠 (tok/s、context の上限など) は移行作業側の実測です。
  # 変更するときは ~/bonsai-workspaces/models.ini 側のコメントも見てください。
  ##########################################################################
  bonsaiModel = "${modelsDir}/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-PTQ1_0.gguf";

  modelsPreset = pkgs.writeText "llama-cpp-models.ini" ''
    version = 1

    ; デバイス名は llama-server --list-devices の表示で、
    ; CUDA_VISIBLE_DEVICES のインデックスより安定しています。
    ;   CUDA0 = RTX 3060 Ti    (7839 MiB, sm_86, テンソルコア有り)
    ;   CUDA1 = GTX 1660 SUPER (5749 MiB, sm_75, テンソルコア無し = プロンプト処理が非常に遅い)
    [*]
    jinja = true

    ; ------------------------------------------------------------------
    ; Bonsai 2 / PTQ1_0 を 3060 Ti 単体で。このホストでの最良構成の実測値:
    ; 33.6-33.8 tok/s。1660 SUPER に 1 層も載せないことが生成で 1.3-1.5 倍、
    ; プロンプト処理で 2.5-3.7 倍に効きます。
    ;
    ; ★ c = 81920 は KV を q4_0 にしたときの CUDA0 単体の上限です ★
    ;   2026-09-22 実測 (llama-cpp を止めて 3060 Ti を空にした状態、
    ;   ctk = ctv = q4_0、np = 1、ngl = 99):
    ;     32768 OK (6674 MiB)   65536 OK (7410 MiB)
    ;     81920 OK (7778 MiB)   90112 NG   98304 NG
    ;   NG 側の失敗は OOM ではなく
    ;     llama_init_from_model: failed to initialize the context:
    ;     failed to allocate compute pp buffers
    ;   です (計算バッファが取れない)。ロード後の空きは 81920 で約 410 MiB。
    ;
    ;   生成速度は 32.75 tok/s (80K、200 トークン生成の実測)。q8_0 / 32768 の
    ;   33.4-33.8 tok/s からほぼ落ちていません — KV 量子化は生成の律速では
    ;   ないためです。代償は KV の精度 (q8_0 → q4_0) だけです。
    ;
    ;   経緯: 16384 (2026-09-22 まで) → 32768 (q8_0 での 1 枚上限) →
    ;   81920。32768 が上限だったのは KV が q8_0 だったからで、q4_0 に
    ;   落とすと 32K あたり約 736 MiB (q8_0 は約 1.5 GiB) に減り、
    ;   同じ 1 枚・同じ速度のまま 2.5 倍の context が載ります。
    ;   2 枚使う [bonsai-long] (144K) と違って生成が 40% 落ちないのが要点です。
    ;
    ;   ★ --models-max を 2 に戻すならここを 16384 前後まで下げること ★
    ;     81920 だと 3060 Ti に約 410 MiB しか残らず、次に起動する
    ;     llama-server の子プロセスが CUDA コンテキストすら作れません —
    ;     ggml は --device で使わないと指定したデバイスにも、見えている
    ;     限りコンテキストを作るためです。
    ; ------------------------------------------------------------------
    [bonsai]
    model = ${bonsaiModel}
    device = CUDA0
    np = 1
    ngl = 99
    c = 81920
    ctk = q4_0
    ctv = q4_0
    temp = 0.5
    top-p = 0.85
    top-k = 20

    ; 同じ重み + vision projector (+600 MB)。その分 context が 8192 に落ちます。
    [bonsai-vision]
    model = ${bonsaiModel}
    mmproj = ${modelsDir}/Ternary-Bonsai-2-27B-gguf/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
    device = CUDA0
    np = 1
    ngl = 99
    c = 8192
    ctk = q8_0
    ctv = q8_0
    temp = 0.5
    top-p = 0.85
    top-k = 20

    ; Qwen3 の埋め込みは CPU で回します (device = none / ngl = 0)。
    ; OpenViking が使う 2560 次元のほう (実機のルーターで測定済み)。
    ;
    ; 以前は CUDA1 (1660 SUPER) に置いていましたが、2026-09-22 に CPU へ
    ; 移しました。当時は models-max 2 のままで [bonsai-long] を載せるためで、
    ; 埋め込みが 1 枚でも VRAM を握っていると OOM したからです。
    ;
    ; ★ ただし同日 models-max は 1 に下げたので、この CPU 配置はもう
    ;   VRAM のためには効いていません ★ (下の ExecStart の経緯を参照)
    ;   1 なら同時に載るモデルは 1 つだけで、GPU に戻しても bonsai-long とは
    ;   衝突しません。CPU のままにしてあるのは実測で warm 66 ms/リクエストと
    ;   十分速く、戻す積極的な理由が無いからです。短い context の常用に戻して
    ;   models-max を 2 に上げるときは、ここを CUDA1 に戻すほうが速くなります。
    ; np は既定の 4 のまま。これは意図的で、埋め込みモデルにはスロットごとに
    ; 増える再帰状態キャッシュが無く、スロットが多いほうが同時リクエストに
    ; 有利だからです。np = 1 が要るのは生成側のプリセットだけです。
    [embedding]
    model = ${modelsDir}/Qwen3-Embedding-4B-GGUF/Qwen3-Embedding-4B-Q4_K_M.gguf
    device = none
    embeddings = true
    pooling = last
    ngl = 0
    c = 8192

    ; Gemma 4 12B (ggml-org の標準 GGUF。ollama の blob は独自形式で
    ; 互換レイヤが要るため、ここからは再利用できません)。2 枚必要。
    ;
    ; np = 1 は 2026-09-21 に追加されたものです。それ以前は [gemma4] だけ
    ; 抜けており (bonsai* にだけ np を足した際の漏れ)、既定の 4 スロットで
    ; 動いて余計な VRAM を使っていました。Open WebUI の Pipe が指すのが
    ; この gemma4 系なので、実害のあるほうの漏れでした。消さないこと。
    [gemma4]
    model = ${modelsDir}/gemma-4-12B-it-GGUF/gemma-4-12B-it-Q4_0.gguf
    mmproj = ${modelsDir}/gemma-4-12B-it-GGUF/mmproj-gemma-4-12B-it-Q8_0.gguf
    np = 1
    ngl = 99
    c = 16384
    split-mode = layer

    ; 同じ Gemma 4 を 32K context で。KV を q8_0 に量子化してその分を捻出。
    ; 用途は n8n の Task Partner Brain (13 個のツールスキーマ + 8 ターンの
    ; バッファウィンドウ + システムプロンプト) と、Open WebUI の Pipe
    ; (title_generation / follow_up_generation) で 16K では足りない場合。
    ;
    ; 32768 は 2026-08-11 以前にそのワークフローが実際に動いていた値です。
    ; その後 163840 に引き上げられたのは、num_ctx を変えるたびに ollama が
    ; モデルを再ロードするのを止めるためだけの措置でした — llama.cpp には
    ; 無い問題なので、本来の 32768 に戻してあります。
    [gemma4-32k]
    model = ${modelsDir}/gemma-4-12B-it-GGUF/gemma-4-12B-it-Q4_0.gguf
    mmproj = ${modelsDir}/gemma-4-12B-it-GGUF/mmproj-gemma-4-12B-it-Q8_0.gguf
    ngl = 99
    c = 32768
    ctk = q8_0
    ctv = q8_0
    np = 1
    split-mode = layer

    ; nomic-embed-text v1.5、768 次元。Open WebUI の RAG が既にこのモデルで
    ; インデックスを作っているため (modules/ollama.nix:306 の
    ; RAG_EMBEDDING_MODEL = "nomic-embed-text")、切り替えで Knowledge の
    ; 作り直しを迫られないように残してあります。Qwen3 の [embedding] は
    ; 別モデルかつ別次元なので、そちらを指すと作り直しが必要になります。
    ;
    ; 次元数は実機のルーターで測定済み: embedding-nomic = 768、
    ; embedding = 2560。埋め込みプリセットが 2 つ併存するのは意図的で、
    ; [embedding] は OpenViking 用、[embedding-nomic] は Open WebUI の RAG 用。
    ; [embedding] と同じ理由で、どちらも CPU 実行にしてあります。
    [embedding-nomic]
    model = ${modelsDir}/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.Q8_0.gguf
    device = none
    embeddings = true
    pooling = mean
    ngl = 0
    c = 8192

    ; ------------------------------------------------------------------
    ; 長い context、2 枚使用。144K が GPU に載る上限 (155648 は OOM)。
    ; 1 枚構成に比べて生成速度は 40% 落ちます (1660 SUPER にテンソルコアが
    ; 無く、そこに載った層がパイプライン全体を律速するため)。
    ; これは 2 枚を埋め尽くすので [embedding] の居場所が無くなります。
    ; ------------------------------------------------------------------
    [bonsai-long]
    model = ${bonsaiModel}
    device = CUDA0,CUDA1
    split-mode = layer
    np = 1
    ngl = 99
    c = 147456
    ctk = q8_0
    ctv = q8_0
    temp = 0.5
    top-p = 0.85
    top-k = 20
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
    description = "llama.cpp router (PrismML fork) — OpenAI-compatible, multi-model";

    # ★ 自動起動しません ★ 上の冒頭コメント参照。ollama と VRAM を取り合う
    # ため、切り替えを決めるまでは手動 (systemctl start llama-cpp) です。
    wantedBy = [ ];

    # GPU が使える状態になってから。modules/ollama.nix:215-218 と同じ理由で、
    # nvidia-persistenced が上がっていればドライバは初期化済みです。
    after = [ "nvidia-persistenced.service" "network.target" ];
    wants = [ "nvidia-persistenced.service" ];

    environment = {
      # ★ PCI_BUS_ID にしないこと ★ 冒頭の長いコメント参照。
      CUDA_DEVICE_ORDER = "FASTEST_FIRST";
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

      ExecStart = lib.concatStringsSep " " [
        "${llamaCppPrism}/bin/llama-server"
        "--models-preset ${modelsPreset}"
        # 同時常駐は 2 モデルまで。VRAM 13.6 GiB では [bonsai] + [embedding] が
        # 現実的な上限で、3 つ目を載せると必ずどれかが溢れます。
        #
        # ★ models-max は 1 です。[bonsai-long] を常用するための値です ★
        #   2026-09-22、opencode の接続先を [bonsai-long] (144K) に切り替えた
        #   際に 1 へ落としました。経緯を残します。
        #
        #   [bonsai-long] は 2 枚 13.6 GiB のうち約 12.4 GiB を使うので、
        #   他の GPU モデルと同時には存在できません。ところがルーターは
        #   VRAM を見ておらず、枠が埋まっていると LRU でしか追い出しません。
        #   models-max 2 のままだと枠は [bonsai](GPU) + [embedding](CPU) で
        #   埋まり、そこへ bonsai-long が来たとき LRU が CPU 側の
        #   [embedding] を選ぶと VRAM が 1 バイトも空きません。結果、
        #     E ggml_backend_cuda_buffer_type_alloc_buffer:
        #       allocating 306.00 MiB on device 0: cudaMalloc failed: OOM
        #     {"error":{"message":"model name=bonsai-long failed to load"}}
        #   が頻発します (実測)。埋め込みを CPU に逃がしたことで、逆に
        #   「追い出しても VRAM が空かないモデル」が生まれたのが効いています。
        #
        #   1 にすると必ず全部アンロードしてからロードするので OOM は
        #   消えます。代償は、[embedding] や [gemma4] が呼ばれるたびに 27B が
        #   落ち、次の生成で再ロードされること (数十秒)。これは承知の上での
        #   選択です (2026-09-22、A: 32K に落として共存 / B: 144K + max 1 /
        #   C: 144K を専有 の 3 択から B を選択)。
        #
        #   [bonsai-long] 実測値 (2026-09-22、単独ロード時):
        #     n_ctx = 147456、CUDA0 5638 + CUDA1 6726 MiB
        #     生成 20.6 tok/s (1 枚の [bonsai] 33.6 tok/s に対し約 40% 減。
        #     上の bonsai-long プリセットのコメントの見積もりどおり)
        #     tool calling も finish_reason = tool_calls で正常
        #     CPU に降りた [embedding] は warm で約 66 ms/リクエスト
        #
        #   ★ 常用モデルを短い context に戻すときは 2 に戻すこと ★
        #     [bonsai](16K) + [embedding] なら 2 のほうが明らかに快適です。
        #     1 のままだと埋め込みのたびに無意味な再ロードが走ります。
        "--models-max 1"
        "--host 127.0.0.1"
        "--port ${toString port}"
      ];

      Restart = "on-failure";
      RestartSec = 10;
    };
  };
}
