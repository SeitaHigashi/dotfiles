{ config, lib, pkgs, ... }:

##############################################################################
# OpenViking (ByteDance/Volcengine 製、AI エージェント向けの自己進化コンテキスト DB。
# Agent Memory / Knowledge RAG / Skills を統合管理する) を podman コンテナで動かす。
#
# 何をしているか:
#   公式配布の OCI イメージ (ghcr.io/volcengine/openviking) を、Multica
#   (modules/multica.nix) や FTB Evolution (modules/ftb-evolution.nix) と同じ
#   podman ベースの構成で動かします。nixpkgs でのパッケージ化はしていません
#   (multica-backend/frontend と同じ判断 — アップストリームの latest イメージを
#   直接 pull する方が単純です)。
#
# 埋め込み/VLM モデル:
#   外部 API キーを使わず、このホストの services.ollama (modules/ollama.nix) を
#   OpenAI 互換バックエンドとして使います。embedding は qwen3-embedding:4b、
#   vlm と query_planner はどちらも qwen3.5:9b (同一モデルを共用) —
#   いずれも modules/ollama.nix の loadModels に追加済みです。ollama は認証を
#   持たないため api_key はダミー値で構いません。
#
#   query_planner に専用モデル guoxuter/ov_intent_analysis_sft:v7_q8 (~0.8B)
#   を割り当てていた時期がありましたが、8GB VRAM (3060 Ti) に embedding
#   (qwen3-embedding:4b, ~4GB) + vlm (qwen3.5:9b, ~5.4GB) + query_planner
#   の3モデルが同時に収まりきらず、OLLAMA_MAX_LOADED_MODELS=2 の上限も相まって
#   リクエストのたびにモデルの evict/再ロードが発生していました
#   (実機の journalctl -u ollama で数分おきの "loading model via llama-server"
#   と "cudaMalloc failed: out of memory" を確認、2026-09-06)。再ロード待ちが
#   OpenViking 側の HTTP タイムアウトを超え、記憶抽出 (extract_loop) とクエリ
#   拡張の両方が定期的に失敗していたため、query_planner を vlm と同じ
#   qwen3.5:9b に統一し常駐モデルを2つ (embedding + vlm) に減らして解消。
#   guoxuter モデルを query_planner 専用に充てる案は、公式ドキュメントが
#   「4B 未満の VLM は記憶抽出に失敗する」と明記している最低ラインを
#   guoxuter (~0.8B) が大きく下回るため、vlm 役としての転用も不可。
#
#   embedding だけ dimension を明示しています。イメージ同梱のブートストラップ
#   コレクションが 2048 次元を前提にしており (実機で "Dense vector dimension
#   mismatch: expected 2048, got 768" を確認)、qwen3-embedding は Matryoshka
#   学習済みで dimensions パラメータによる出力次元の切り詰めに対応しているため、
#   nomic-embed-text (固定768次元) ではなくこちらを選び 2048 に合わせています。
#
#   vlm は名前に反して「画像理解専用」ではなく、記憶抽出 (extract_loop)・
#   クエリ拡張・L0/L1 の要約生成など OpenViking のほぼ全生成処理が
#   config.vlm.get_completion_async() 経由で使う汎用 LLM 設定です
#   (openviking/session/memory/extract_loop.py 等で実機確認)。当初ここに
#   moondream (1.7B, 視覚特化) を割り当てていたところ、
#   "LLM returned neither tool calls nor operations" で記憶抽出が
#   常に失敗していました。公式の openviking_cli/setup_wizard.py に
#   「qwen3.5:4b 未満の VLM は記憶抽出に失敗する (few-shot 例をそのまま
#   偽の記憶として複製する)」と明記されており、4B を大きく下回る moondream は
#   この最低ラインの対象外でした。
#
#   4B 以上なら何でもよいわけではなく、次に試した gemma4:12b (12B、embedding
#   の qwen3-embedding とモデルファミリーを揃える必要はない — 公式プリセットも
#   32-64GB 帯では qwen3-embedding + gemma4 の組み合わせを推奨) は
#   num_ctx/think を明示指定してもなお、extract_loop の tool_choice="auto" の
#   もとでツール呼び出しの代わりに自然文の要約を返すことがあり
#   ("Failed to parse memory operations ... Expected dict after parsing"
#   を実機で確認)。3 回のリトライで最終的には帳尻が合うことが多いものの、
#   1 レコードあたり平均 70 秒前後かかっており (実機で 9 レコード 625 秒)、
#   ツール呼び出し遵守性が低い分リトライが嵩んでいると見られる。
#   openviking_cli/setup_wizard.py の VLM プリセットは Qwen 系
#   (qwen3.5:4b/9b/27b/35b/122b) が主軸で、Gemma は 32-64GB 帯の代替枠
#   だけだったことを踏まえ、qwen3.5:9b (16-32GB 帯の公式プリセット、
#   tools ケイパビリティを持つことを ollama show で確認済み) に切り替えて
#   いる。なお画像パーサ (ImageConfig.enable_vlm) もこの同じ vlm を使うため、
#   moondream からの切り替えで画像理解の特性が変わる点はトレードオフとして
#   残ります。
#
# 公開範囲:
#   Tailscale Serve のサブパス越しにはせず、Ollama (11434) と同じパターンで
#   コンテナに --network=host を渡し、ホストの 0.0.0.0:1933 に直接 bind させて
#   ファイアウォールの tailscale0 インタフェース制限だけで絞ります。
#   host network を選ぶ理由: rootful podman の bridge/NAT 経由だと、コンテナから
#   ホストの ollama (127.0.0.1:11434) への到達性や、公開ポートに対する
#   ファイアウォールの interface フィルタの効き方が曖昧になるためです
#   (Minecraft は同種の問題を LAN 直結アドレス縛りという別の回避策で凌いでいます。
#   modules/ftb-evolution.nix の listenAddress のコメント参照)。
#   modules/reverse-proxy.nix の routes には加えていません — Ollama と同じ理由
#   (CLI/API クライアントはベース URL にパスを含められない) です。
#
# データ:
#   dpool (HDD mirror) 上の専用データセット /var/lib/openviking を
#   コンテナの /app/.openviking にバインドマウントします (disko/default.nix)。
#
# 秘密情報 (root_api_key):
#   0.0.0.0 で待ち受けるサーバーは root_api_key が無いと起動を拒否します。
#   ov.conf は秘密情報と非秘密情報が混在する 1 ファイルのため、multica の
#   ような --secret 注入ではなく、起動前の oneshot ユニットで静的テンプレートと
#   agenix から読んだ root_api_key を合成してワークスペース配下に書き出します。
##############################################################################

let
  port = 1933;

  workspaceDir = "/var/lib/openviking";

  rootApiKeyFile = config.age.secrets.openviking-root-api-key.path;

  ollamaBaseUrl = "http://127.0.0.1:11434/v1";

  # ov.conf の非秘密部分。root_api_key だけ oneshot ユニットで差し込みます。
  # provider は "openai" (OpenAI API 互換の一般値、openviking のコンテナイメージ内
  # openviking_cli/utils/config/{embedding,vlm}_config.py の EmbeddingModelConfig/
  # VLMConfig で確認済み)。
  #
  # embedding だけ vlm と構造が異なる点に注意: EmbeddingConfig は provider/api_base
  # を直下に持たず、dense/sparse/hybrid のいずれかにネストした EmbeddingModelConfig
  # を要求します (embedding_config.py の EmbeddingConfig.validate_config)。
  # 直下に置くと "Unknown config field 'embedding.api_base'" 等で起動時に落ちます
  # (実機で確認済み)。vlm は VLMConfig がフラットな構造のためそのままで問題ありません。
  ovConfTemplate = pkgs.writeText "ov.conf.template" (builtins.toJSON {
    server = {
      host = "0.0.0.0";
      inherit port;
      cors_origins = [ "*" ];
    };
    storage = {
      workspace = "/app/.openviking/data";
      agfs.backend = "local";
      vectordb.backend = "local";
    };
    embedding = {
      dense = {
        provider = "openai";
        api_base = ollamaBaseUrl;
        api_key = "ollama"; # ollama は認証しないためダミー値
        model = "qwen3-embedding:4b";
        dimension = 2048; # ブートストラップコレクションの想定次元に合わせる (上記コメント参照)
      };
    };
    vlm = {
      provider = "openai";
      api_base = ollamaBaseUrl;
      api_key = "ollama";
      model = "qwen3.5:9b";
      # 上のコメントの通り、ここは provider="openai" 経由 (litellm の
      # "ollama/" プレフィックス判定を通らない) なので、openviking 側の
      # num_ctx=16384 自動注入 (litellm_vlm.py の OLLAMA_DEFAULT_NUM_CTX)
      # が効かず、Ollama の既定コンテキスト長で記憶抽出の長いプロンプトが
      # 黙って切り詰められる。モデル自体の Modelfile を大コンテキスト用の
      # 別タグに差し替える (gemma4:12b-163k で一度試した) と、KV キャッシュが
      # VRAM を圧迫し embedding (qwen3-embedding:4b) との同時ロードで
      # "cudaMalloc failed: out of memory" を実機で確認したため、
      # extra_request_body で必要十分な num_ctx を直接指定する方式にしている。
      #
      # think=false も同じ理由 (provider="openai" 経由だと litellm_vlm.py の
      # "ollama/" プレフィックス判定に乗らず、Ollama 向けの think 既定値
      # 注入も効かない) で明示指定が必要。qwen3.5:9b は thinking ケイパビリ
      # ティを持つため、無指定だと推論過程のトークンを毎回生成してしまい
      # (記憶抽出/クエリ拡張のような JSON 構造化出力だけが欲しい用途では
      # 純粋なオーバーヘッド)、レイテンシと VRAM 上の KV キャッシュ消費が
      # 余計にかかる。extra_request_body の項目説明にも Ollama 向けの
      # 例としてそのまま {"think": false} が挙げられている。
      extra_request_body = { num_ctx = 16384; think = false; };
    };
    query_planner = {
      provider = "openai";
      api_base = ollamaBaseUrl;
      api_key = "ollama";
      model = "qwen3.5:9b"; # vlm と同じモデルに統一 (下記コメント参照)。
      # think=false は vlm と同じ理由 (provider="openai" 経由だと Ollama 向けの
      # think 既定値注入が効かない) で明示指定。num_ctx はクエリ展開の
      # プロンプトが短いため既定のままで問題ない。
      extra_request_body = { think = false; };
    };
  });
in
{
  age.secrets.openviking-root-api-key = {
    file = ../secrets/openviking-root-api-key.age;
    mode = "0400";
  };

  ############################################################################
  # データディレクトリ (dpool/var/lib/openviking, disko/default.nix)
  #
  # コンテナは root で動く (公式 Dockerfile に USER 指定なし) ため、
  # FTB Evolution のような uid/gid 合わせは不要です。
  ############################################################################
  systemd.tmpfiles.rules = [
    "d ${workspaceDir} 0700 root root -"
  ];

  ############################################################################
  # ov.conf を起動前に合成する。
  #
  # 静的テンプレート (ovConfTemplate) の JSON に root_api_key を jq で足して
  # ワークスペース直下に書き出します。podman-openviking.service より先に
  # 完了している必要があるため before/requires で縛ります
  # (modules/multica.nix の multica-github-secret と同型)。
  ############################################################################
  systemd.services.openviking-conf = {
    description = "Render OpenViking ov.conf with root_api_key from agenix";
    before = [ "podman-openviking.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "openviking-render-conf" ''
        set -euo pipefail
        ${pkgs.jq}/bin/jq \
          --arg root_api_key "$(cat ${rootApiKeyFile})" \
          '.server.root_api_key = $root_api_key' \
          ${ovConfTemplate} > ${workspaceDir}/ov.conf.tmp
        mv ${workspaceDir}/ov.conf.tmp ${workspaceDir}/ov.conf
        chmod 0600 ${workspaceDir}/ov.conf
      '';
    };
  };

  systemd.services.podman-openviking = {
    after = [ "openviking-conf.service" ];
    requires = [ "openviking-conf.service" ];
  };

  ############################################################################
  # コンテナ
  ############################################################################
  virtualisation.oci-containers.containers.openviking = {
    image = "ghcr.io/volcengine/openviking:latest";
    volumes = [ "${workspaceDir}:/app/.openviking" ];
    extraOptions = [
      # 0.0.0.0:1933 に直接 bind させ、ホストの ollama (127.0.0.1:11434) にも
      # 素通りで到達させる。上記コメント参照。
      "--network=host"
    ];
    autoStart = true;
  };

  ############################################################################
  # 公開範囲: tailscale0 のみ。LAN には出しません (Ollama と同じ方針)。
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ port ];

  ############################################################################
  # 運用メモ
  #
  #   状態確認:
  #     systemctl status openviking-conf podman-openviking
  #     journalctl -u podman-openviking -f
  #
  #   疎通確認 (tailnet 内の別ホストから):
  #     curl http://<tailscale IP>:1933/...
  #     (LAN や 127.0.0.1 以外からは firewall で弾かれます)
  #
  #   イメージ更新:
  #     podman pull ghcr.io/volcengine/openviking:latest
  #     systemctl restart podman-openviking
  #
  #   秘密情報の再発行:
  #     nix-shell -p openssl age --run '...' で新しい root_api_key を作り、
  #     secrets/openviking-root-api-key.age を作り直して switch。
  #     ov.conf は openviking-conf.service が次回起動時に自動で書き直します。
  #
  #   データ場所:
  #     /var/lib/openviking (dpool/var/lib/openviking, disko/default.nix)。
  #     zfs list dpool/var/lib/openviking で使用量確認。
  ############################################################################
}
