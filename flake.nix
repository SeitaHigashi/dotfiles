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
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

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
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, agenix, ... }@inputs:
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
        ./modules/alerting.nix         # Grafana のアラート (通知は n8n Webhook)
        ./modules/ollama.nix           # ローカル LLM (Ollama + Open WebUI)
        ./modules/n8n.nix              # ワークフロー自動化 (unstable 追従)
        ./modules/comfyui.nix          # 画像生成 (ComfyUI, comfy-cli 経由の venv)
        ./modules/multica.nix          # Multica (AI エージェント管理) を podman で自前ホスト
        ./modules/reverse-proxy.nix    # Tailscale Serve で HTTP サービスを集約
        ./modules/resource-priority.nix # サービス間の CPU / メモリ優先度
        ./modules/discord-bot.nix      # Discord Gateway ボット -> n8n webhook
      ];
    };
  };
}
