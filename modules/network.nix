{ config, lib, pkgs, ... }:

##############################################################################
# ネットワーク設定。
#
# machine.nix の staticAddress が
#   - 文字列 ("192.168.11.254/24" など) … systemd-networkd で静的 IP
#   - null                              … NetworkManager + DHCP
# のどちらかに切り替わります。
#
# 静的 IP のときに NetworkManager を止めているのは、両者を同時に有効にすると
# 同じインタフェースを取り合って IP が付いたり消えたりするためです。
# サーバ用途では systemd-networkd の方が宣言的で挙動が読みやすくなります。
##############################################################################

let
  m = import ../machine.nix;
  static = m.staticAddress != null;
in
{
  # 静的 IP のときは networkd に任せるので、NixOS 側の DHCP は全体で無効にする。
  # (これを残すと全インタフェースで DHCP が走り、静的設定と競合します)
  networking.useDHCP = lib.mkDefault (!static);

  networking.networkmanager.enable = !static;

  ############################################################################
  # 静的 IP
  ############################################################################
  systemd.network = lib.mkIf static {
    enable = true;

    # 有線が1本しかない構成では、そのインタフェースが上がるまで待てば十分。
    # 複数 NIC で片方だけ繋ぐ場合に起動が止まるのを防ぎます。
    wait-online.anyInterface = true;

    networks."10-lan" = {
      matchConfig.Name = m.networkInterface;

      address = [ m.staticAddress ];
      gateway = [ m.gateway ];
      dns = m.nameservers;

      # IPv6 はルータからの広告を受け入れる (不要なら false)
      networkConfig.IPv6AcceptRA = true;

      # ネットワークが繋がるまで systemd に待たせる対象。
      # "routable" = 経路が引けるまで。付けないと、起動直後に
      # ネットワークを要求するサービスが失敗することがあります。
      linkConfig.RequiredForOnline = "routable";
    };
  };

  # resolv.conf にも同じ DNS を書く。
  # systemd-resolved を使わない構成なので、これが無いと名前解決できません。
  networking.nameservers = lib.mkIf static m.nameservers;

  ############################################################################
  # ファイアウォール
  #
  # services.openssh.enable = true が 22/tcp を自動で開けます。
  # 他のポート (Minecraft の 25565 等) が必要になったらここに足してください。
  #   networking.firewall.allowedTCPPorts = [ 25565 ];
  ############################################################################
  networking.firewall.enable = lib.mkDefault true;
}
