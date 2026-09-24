{ config, lib, pkgs, ... }:

##############################################################################
# fukurou (ローカル音声対話ループ、Rust 製、~/fukurou で開発中の自前アプリ)。
#
# 何のために入れるか:
#   fukurou-server が STT (whisper.cpp) → LLM (claude CLI) → TTS (VOICEVOX
#   core) の一連の処理を担い、fukurou-webui はそれをブラウザから
#   push-to-talk で叩くための開発用テストページ (README 参照、正式な GUI
#   ではない)。どちらもこれまで seita が手動でフォアグラウンド起動していた
#   ものを、常駐サービスとして tailnet から使えるようにする。
#
# ビルド方式:
#   nixpkgs にパッケージ化はせず、~/fukurou (このホストの seita の作業用
#   チェックアウト) を直接 WorkingDirectory にして
#   target/release/ の実行済みバイナリを ExecStart で叩く。comfyui.nix の
#   pip venv 管理と同種の「Nix はプロセス起動だけを面倒見る」パターン。
#   バイナリの再ビルドは手動 (cd ~/fukurou && nix develop --command cargo
#   build --release -p fukurou-server -p fukurou-webui) で、更新したら
#   systemctl restart fukurou-server fukurou-webui する。
#
# なぜ User=seita か:
#   llm.backend = "claude" (config/server.toml) は `claude` CLI をサブ
#   プロセスとして呼ぶ。認証状態は seita の ~/.claude/ 配下にあるため、
#   DynamicUser や専用ユーザーではなく seita 本人として動かす必要がある。
#
# 実行時の共有ライブラリ (libvulkan.so.1 など) は ldd で確認済みで、
# `nix develop` でビルドしたバイナリに絶対パスの RPATH が焼き込まれている
# ため、systemd ユニット側で LD_LIBRARY_PATH を組む必要はない
# (2026-08-30 実機確認)。VOICEVOX core / onnxruntime の .so は
# config/server.toml の相対パス (models/voicevox_core/...) からアプリが
# 自前で dlopen するため、WorkingDirectory が合っていることだけが条件。
#
# GPU:
#   whisper.cpp (STT) が Vulkan 経由で GPU を使う (modules/gpu.nix 参照)。
#   2026-09-22 に GGML_VK_VISIBLE_DEVICES = "1" で GTX 1660 SUPER に固定し、
#   RTX 3060 Ti を llama.cpp のモデル専用に空けました。CUDA の環境変数では
#   動かせない理由と、Vulkan のインデックスが nvidia-smi と逆である点は
#   下の fukurou-server のコメントに書いてあります。
#   VRAM 衝突ガードは用意していない — 音声対話は単発の短い推論なので、
#   ロード待ちが起きる程度で済む想定。問題が出るようなら
#   comfyui-vram-guard 相当の仕組みを検討すること。
##############################################################################

let
  m = import ../machine.nix;
  fukurouDir = "/home/${m.userName}/fukurou";
  ports = {
    server = 7878; # fukurou-server の WebSocket
    webui = 8765;  # fukurou-webui (開発用テストページ)
  };

  # claude CLI は `nix profile install` で入れた imperative なプロファイル
  # (~/.nix-profile) にある。systemd ユニットの既定 PATH には含まれないため、
  # systemd.services.<n>.path (中身は makeBinPath に渡り "<entry>/bin" が
  # PATH に足される、追記型のオプション) で補う。environment.PATH を直接
  # 上書きすると既定 PATH の定義と conflicting definition で評価エラーになる
  # ため使わない (2026-08-30 実機確認)。
  userNixProfile = "/home/${m.userName}/.nix-profile";

  # claude CLI が呼ぶ SessionEnd フック (session-end.mjs) が node を要求するが、
  # node は home-manager 経由 (/etc/profiles/per-user/<user>) で入っており
  # ~/.nix-profile には無い。上と同じ理由でこのユニットの PATH にも足す必要が
  # あり、無いと "node: command not found" がフック失敗として毎回ログに出る
  # (2026-08-30 に実機の journal で確認)。
  userHomeManagerProfile = "/etc/profiles/per-user/${m.userName}";
in
{
  ############################################################################
  # fukurou-server (音声対話の本体、WebSocket 7878)
  ############################################################################
  systemd.services.fukurou-server = {
    description = "fukurou-server (voice conversation loop: STT -> LLM -> TTS)";

    after = [ "network.target" "nvidia-persistenced.service" ];
    wants = [ "nvidia-persistenced.service" ];
    wantedBy = [ "multi-user.target" ];

    path = [ userNixProfile userHomeManagerProfile ];

    ########################################################################
    # whisper.cpp (STT) を GTX 1660 SUPER に固定する。
    #
    # ★ CUDA の環境変数は効きません ★
    #   fukurou-server が GPU に触る経路は Vulkan だけです
    #   (ldd に libvulkan.so.1 のみ、CUDA/cuBLAS はリンクされていない。
    #    2026-09-22 実機確認)。したがって modules/ollama.nix や
    #    modules/llama-cpp.nix が使う CUDA_VISIBLE_DEVICES /
    #    CUDA_DEVICE_ORDER はこのユニットには一切影響しません。
    #
    # ggml の Vulkan バックエンド (whisper-rs-sys 0.11.1 同梱の
    # ggml/src/ggml-vulkan.cpp:2117 "Emulate behavior of
    # CUDA_VISIBLE_DEVICES for Vulkan") が GGML_VK_VISIBLE_DEVICES を
    # カンマ区切りのインデックスとして読み、指定が無ければ discrete GPU を
    # 全部使います。
    #
    # ★ インデックスは nvidia-smi の番号ではありません ★
    #   Vulkan 独自の列挙順で、このホストでは逆になります
    #   (vulkaninfo --summary で実測、2026-09-22):
    #     Vulkan 0 = RTX 3060 Ti      (nvidia-smi では 1)
    #     Vulkan 1 = GTX 1660 SUPER   (nvidia-smi では 0)
    #     Vulkan 2 = llvmpipe (Mesa のソフトウェア実装、CPU)
    #   たまたま CUDA の FASTEST_FIRST と同じ並びですが別系統なので、
    #   「CUDA1 だから 1」という覚え方をしないこと。
    #
    # 何のために寄せるか:
    #   3060 Ti (CUDA0) を llama.cpp のモデル専用にするためです。fukurou は
    #   待機中も約 478 MiB を握り続けます (実測)。1660 SUPER 側の予算は
    #   5.7 GiB で、ここに埋め込みプリセットを置く構想があるので
    #   (docs/gpu-vram-budget.md 参照)、478 MiB を先に引いて考えてください。
    #
    # ★ 未検証: VOICEVOX core の onnxruntime ★
    #   478 MiB はモデルサイズ (ggml-small.bin = 465 MB) とほぼ一致するので
    #   whisper.cpp の分と見て矛盾しませんが、onnxruntime が GPU を使って
    #   いないかは確かめていません。使っていればこの変数では動かせません
    #   (onnxruntime 側の provider 設定になります)。切り替え後に
    #   nvidia-smi でカード別の内訳を実測して確認すること。
    ########################################################################
    environment.GGML_VK_VISIBLE_DEVICES = "1";

    serviceConfig = {
      Type = "simple";
      User = m.userName;
      WorkingDirectory = fukurouDir;
      ExecStart = "${fukurouDir}/target/release/fukurou-server --config config/server.toml";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  ############################################################################
  # fukurou-webui (開発用テストページ、127.0.0.1 のみ)
  #
  # index.html はビルド時に include_str! でバイナリに埋め込まれるため、
  # WorkingDirectory は必須ではないが、他ユニットと揃えて指定しておく。
  # 待ち受けは 127.0.0.1 に絞り、tailnet への到達は下の
  # modules/reverse-proxy.nix (Tailscale Serve) 経由のみにする — fukurou-server
  # と違い生の WebSocket ではなく普通の HTTP ページなので、Ollama 方式
  # (0.0.0.0 + firewall) ではなく Open WebUI や Grafana と同じ方式に揃える。
  ############################################################################
  systemd.services.fukurou-webui = {
    description = "fukurou-webui (browser test client for fukurou-server)";

    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = m.userName;
      WorkingDirectory = fukurouDir;
      ExecStart = "${fukurouDir}/target/release/fukurou-webui --bind 127.0.0.1:${toString ports.webui}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  ############################################################################
  # 公開範囲
  #
  # fukurou-server: 生の WebSocket で、ブラウザ以外のクライアントからも
  # ws://<tailscale-ip-or-magicdns>:7878 に直結させたいため、Ollama と同じ
  # 「0.0.0.0 で待ち受け、firewall で tailscale0 のみ開ける」方式にする。
  #
  # ★ ただし fukurou-webui (下記) は https:// で配っているため、ブラウザは
  #   そこから ws:// への接続を mixed content としてブロックする ★
  #   (2026-08-30 実機で確認)。そのため fukurou-server は
  #   modules/reverse-proxy.nix にも wss:// 用のルート (9447) で二重公開して
  #   おり、webui/index.html はページが https のときそちらを既定値にする。
  #   ws://:7878 直結はブラウザ以外のクライアント用にそのまま残している。
  #
  # fukurou-webui: 127.0.0.1 待ち受けなので firewall での追加開放は不要。
  # tailnet からの到達は modules/reverse-proxy.nix の routes に別途追加する。
  ############################################################################
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [
    ports.server
  ];
}
