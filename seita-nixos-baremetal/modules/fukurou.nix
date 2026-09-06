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
#   whisper.cpp は Vulkan 経由で ollama/comfyui と同じ GPU を使う
#   (modules/gpu.nix 参照)。VRAM 衝突ガードは用意していない — 音声対話は
#   単発の短い推論なので、ollama 同様ロード待ちが起きる程度で済む想定。
#   問題が出るようなら comfyui-vram-guard 相当の仕組みを検討すること。
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

    path = [ userNixProfile ];

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
