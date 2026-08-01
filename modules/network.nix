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

  # 上流 DNS。これが無いと名前解決できません。
  #
  # 実際に引くのは systemd-resolved です。上で systemd.network.enable = true に
  # すると nixpkgs 側 (nixos/modules/system/boot/networkd.nix) が
  # services.resolved.enable = mkDefault true を立てるため、静的 IP のときは
  # resolved が必ず有効になります。したがって /etc/resolv.conf の中身は
  # ここの値ではなく resolved の stub (127.0.0.53) で、この値は resolved の
  # Global DNS として使われます (resolvectl status で確認できます)。
  #
  # これは Tailscale の MagicDNS にとって都合が良い状態です。tailscaled は
  # resolved に対して tail*.ts.net 宛だけを 100.100.100.100 へ振り分ける
  # split DNS を登録します。resolved を切ると
  # modules/reverse-proxy.nix の FQDN が引けなくなります。
  networking.nameservers = lib.mkIf static m.nameservers;

  ############################################################################
  # ファイアウォール
  #
  # services.openssh.enable = true が 22/tcp を自動で開けます。
  # 他のポート (Minecraft の 25565 等) が必要になったらここに足してください。
  #   networking.firewall.allowedTCPPorts = [ 25565 ];
  ############################################################################
  networking.firewall.enable = lib.mkDefault true;

  ############################################################################
  # Tailscale
  #
  # 何のために入れるか:
  #   Grafana (modules/monitoring.nix) のような管理用 UI を、ポートを
  #   1 つも開けずに外から見られるようにするためです。代替案は
  #   「ポート開放 + リバースプロキシ + ACME + 認証」のフルセットで、
  #   得られるものに対して構築量と攻撃面が明らかに割に合いません。
  #
  #   もう 1 つの狙いは SSH です。現状 machine.nix の allowPasswordAuth が
  #   true で、公開鍵は空のままです。tailnet 経由でのアクセスに寄せてから、
  #   パスワード認証を切るのが本来の順序です。
  #
  # 注意:
  #   これは Minecraft の 25565 公開とは無関係です。25565 は LAN 向けに
  #   開いたままで、Tailscale を入れても閉じません。
  #
  # 初回のみ手動でログインが必要です (対話でブラウザ認証):
  #   sudo tailscale up
  #   tailscale ip -4
  ############################################################################
  services.tailscale = {
    enable = true;

    # tailscale0 を信頼インタフェースとして firewall に登録し、
    # UDP のダイレクト接続ポートも自動で開けてもらう。
    # これが無いと NAT 越えに失敗して DERP 中継経由になり、遅くなります。
    openFirewall = true;
  };
}
