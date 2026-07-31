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
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, disko, ... }@inputs:
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
        ./modules/monitoring.nix       # VictoriaMetrics + Grafana
        ./modules/ollama.nix           # ローカル LLM (Ollama + Open WebUI)
        ./modules/resource-priority.nix # サービス間の CPU / メモリ優先度
      ];
    };
  };
}
