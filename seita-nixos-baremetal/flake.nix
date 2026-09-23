{
  description = "NixOS on ZFS — SSD x1 (rpool) + HDD x2 mirror (dpool), disko 管理";

  inputs = {
    ############################################################################
    # システムの土台は stable。
    #
    # カーネル・ZFS・systemd・initrd といった「壊れると起動できなくなる」部分は
    # すべてこちらから来ます。ZFS はカーネルのリリースに追従しないことがあるため、
    # ここを unstable にすると rebuild のたびに起動不能のリスクを背負います。
    ############################################################################
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    ############################################################################
    # 個別のツールだけを新しくするための追加入力。
    #
    # modules/unstable.nix のリストに書いたパッケージだけがこちらから来ます。
    # カーネルモジュール (ZFS 等) をここから引いてはいけません。
    # カーネル本体と同じ nixpkgs でビルドされている必要があるためです。
    ############################################################################
    # ★ リビジョンを明示的に固定しています。nixos-unstable に戻さないこと ★
    #
    #   このホストは nodejs をソースからビルドできません。Nix のサンドボックス内で
    #   nodejs のテスト parallel/test-fs-cp-async-file-modes が setuid ビットの
    #   chmod に失敗します:
    #     Error: EPERM: operation not permitted, chmod '.../copy_%1/suid'
    #   (/tmp と / の ZFS は nosuid ではなく setuid=on なので、マウントオプション
    #    側の問題ではありません。2026-09-21 に切り分け済み。)
    #
    #   nixpkgs の llama-cpp (modules/llama-cpp.nix) は Web UI を npm でビルド
    #   するため nodejs_latest に無条件で依存します。したがって nodejs-slim が
    #   バイナリキャッシュに無いリビジョンを掴むと、システム全体がビルド不能に
    #   なります。nixos-unstable は動くブランチなので、固定しないと「ある日突然
    #   rebuild が通らなくなる」形でこれを踏みます。実際 2026-09-21 に旧 pin
    #   (e554fab7, 2026-09-17) で踏みました。hydra はチャンネルのリビジョンしか
    #   ビルドしないため、キャッシュの有無はリビジョンの新旧とは無関係です。
    #
    #   ★ このリビジョンを上げるときの必須チェック ★
    #     キャッシュに nodejs-slim があることを確認してから上げること。
    #       nix path-info --store https://cache.nixos.org <nodejs-slim の out パス>
    #     null が返るリビジョンは採用しないこと。
    #
    #   20b1ddd (2026-09-19) を選んだ理由: nodejs-slim 26.9.0 がキャッシュ済みで、
    #   この構成の toplevel ビルドが実機で通ることを確認済み。旧 pin との差分は
    #   opencode 1.18.30 -> 1.18.31 と ollama-cuda 0.34.0 -> 0.34.2 のみ
    #   (両リビジョンを eval して比較)。
    #
    # nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/20b1ddd1aa5ace70c9468305030aa4f9ef79671b";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # 秘密情報 (Discord Bot Token 等) を git に暗号化したまま置くための agenix。
    # 復号鍵はこのホスト自身の SSH ホスト鍵を流用する (secrets/secrets.nix 参照)。
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ユーザー環境 (dotfiles/home-manager/home.nix) を NixOS モジュールとして
    # 取り込む。nixos/ (mac/wsl) と同じパターン (../home-manager/home.nix を
    # そのまま import) で、home-manager/ 自体は独立した standalone flake の
    # ままなので `home-manager switch --flake ./home-manager` でも別途使える。
    # home-manager は system と同じ stable (nixos-25.05) 系列の release-25.05
    # ブランチに固定する。master (unstable 前提) を stable nixpkgs と組み合わせると
    # home-manager モジュール内部が要求する lib が stable 側に無くて評価エラーになる
    # ため (2026-08-29 実機確認)。unstable の個別パッケージが home-manager 側で
    # 欲しい場合は modules/unstable.nix と同じ pkgs.unstable overlay 経由で使う
    # (useGlobalPkgs = true にしてあるので home.nix からも pkgs.unstable.<name> が
    # そのまま参照できる)。
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, agenix, home-manager, ... }@inputs:
  let
    # 構成名をホスト名と一致させる。
    # nixos-rebuild は --flake に属性名を省略すると、実行中マシンの
    # hostname を構成名として探すため、これで
    #   sudo nixos-rebuild switch --flake /etc/nixos
    # と書けるようになります (#<名前> の指定が不要)。
    m = import ./machine.nix;
  in {
    nixosConfigurations.${m.hostName} = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        agenix.nixosModules.default
        disko.nixosModules.disko
        ./disko                        # ディスク・プール・データセットの宣言
        ./hardware-configuration.nix   # nixos-generate-config --no-filesystems の出力
        ./configuration.nix
        ./modules/zfs.nix
        ./modules/network.nix          # 静的 IP / DHCP の切り替え
        ./modules/replication.nix      # rpool -> dpool の定期複製
        ./modules/unstable.nix         # pkgs.unstable.* を使えるようにする
        ./modules/ftb-evolution.nix    # Minecraft (FTB Evolution) を podman で
        ./modules/gpu.nix              # NVIDIA ドライバ (計算用途 + 監視のため)
        ./modules/unfree.nix           # unfree パッケージの許可一覧 (allowUnfreePredicate の唯一の定義場所)
        ./modules/desktop.nix          # KDE Plasma (X11) — プロジェクター投影用
        ./modules/monitoring.nix       # VictoriaMetrics + Grafana
        ./modules/zfs-snapshot-metrics.nix # スナップショット / 複製状況のメトリクス
        ./modules/gpu-xid-metrics.nix  # NVIDIA Xid (GPU fallen off the bus 等) のメトリクス
        ./modules/nix-info.nix         # インストール済みパッケージ一覧 / Hydra ビルド状況のメトリクス
        ./modules/nix-profile-info.nix # user の nix profile の内容 / 更新有無のメトリクス
        ./modules/alerting.nix         # Grafana のアラート (通知は n8n Webhook)
        ./modules/ollama.nix           # ローカル LLM (Ollama + Open WebUI)
        ./modules/llama-cpp.nix        # ローカル LLM (llama.cpp PrismML フォークのルーター、Ollama の置き換え候補・既定では停止)
        ./modules/n8n.nix              # ワークフロー自動化 (unstable 追従)
        ./modules/comfyui.nix          # 画像生成 (ComfyUI, comfy-cli 経由の venv)
        ./modules/multica.nix          # Multica (AI エージェント管理) を podman で自前ホスト
        ./modules/openviking.nix       # OpenViking (AI エージェント向けコンテキスト DB) を podman で自前ホスト
        ./modules/reverse-proxy.nix    # Tailscale Serve で HTTP サービスを集約
        ./modules/resource-priority.nix # サービス間の CPU / メモリ優先度
        ./modules/discord-bot.nix      # Discord Gateway ボット -> n8n webhook
        ./modules/fukurou.nix          # fukurou (音声対話ループ、~/fukurou) の systemd 化
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.seita = import ../home-manager/home.nix;
          home-manager.extraSpecialArgs = { inherit inputs; };
          home-manager.backupFileExtension = "backup";
        }
      ];
    };
  };
}
