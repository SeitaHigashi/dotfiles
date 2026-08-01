{ inputs, config, lib, pkgs, ... }:

##############################################################################
# stable ベースのまま、選んだツールだけ unstable から引くための仕組み。
#
# なぜこの向きなのか:
#   「カーネルだけ stable、他は unstable」はできません。カーネルモジュール
#   (ZFS を含む) はカーネル本体と同じ nixpkgs でビルドされている必要があり、
#   カーネル・ZFS・kmod 群は分離不可能なセットだからです。
#   そのため逆に、土台を stable に固定したうえで、葉のパッケージだけを
#   unstable から取ってきます。
#
# 使い方:
#   下の unstablePackages にパッケージ名を足すだけ。
#   個別に参照したい場合は他のモジュールから pkgs.unstable.<name> と書けます。
#
# 入れてはいけないもの:
#   - カーネル / カーネルモジュール (linuxPackages*, zfs, nvidia ドライバ等)
#   - systemd, glibc, systemd-boot まわり
#   いずれも起動不能に直結します。ここは「ユーザーが直接使うツール」専用です。
#
# 注意:
#   unstable 由来のパッケージは依存ライブラリも unstable 側のものを引くため、
#   その分だけビルド/ダウンロードが増えます (stable 側と共有されない)。
#   数個〜十数個なら誤差ですが、大きなものを大量に入れると効いてきます。
##############################################################################

let
  # ここに書いたものが unstable から来ます。
  unstablePackages = with pkgs.unstable; [
    neovim

    # Grafana Labs 公式の MCP サーバー。Claude Code から Grafana の
    # ダッシュボードやアラート、VictoriaMetrics への PromQL を読むために使います。
    # stable 25.05 には無いパッケージなので unstable から。
    #
    # 起動設定 (URL とトークンのファイルパス、--disable-write) は
    # このリポジトリではなく ~/.claude.json 側にあります — MCP クライアントの
    # 設定であって NixOS の構成ではないためです。詳細は CLAUDE.md を参照。
    mcp-grafana
  ];
in
{
  nixpkgs.overlays = [
    (final: prev: {
      unstable = import inputs.nixpkgs-unstable {
        inherit (final.stdenv.hostPlatform) system;
        # unfree の許可設定などを stable 側と揃える
        inherit (prev) config;
      };
    })
  ];

  environment.systemPackages = unstablePackages;
}
