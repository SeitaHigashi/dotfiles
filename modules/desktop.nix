{ config, lib, pkgs, ... }:

##############################################################################
# デスクトップ環境 (プロジェクター投影用)
#
# 通常はヘッドレス運用ですが、プロジェクターに繋いで使う場面のために
# KDE Plasma (X11 セッション) を追加します。
#
# GPU の切り分け方針:
#   表示専任として GT1030 (Pascal) を増設していましたが 2026-08-12 に撤去し、
#   プロジェクターの HDMI は 1660 SUPER (bus 4, Ollama/ComfyUI の計算にも
#   使っているカード) に繋ぎ変えました。したがって投影中は 1660 SUPER の
#   VRAM と演算を X (Xorg) とも取り合います (modules/gpu.nix 参照)。
#   2 枚とも NVIDIA なので services.xserver.videoDrivers = [ "nvidia" ]
#   (modules/gpu.nix) がそのままドライバをカバーしますが、何も指定しないと
#   Xorg がどのカードで起動するか不定なため、BusID を明示しています
#   (下記 deviceSection 参照)。
#
# Wayland ではなく X11 を選んだ理由:
#   プロジェクターは常時接続ではなく「たまに挿す」外部出力です。
#   xrandr/autorandr は EDID の怪しい投影機へのホットプラグ対応の実績が
#   厚く、投影用途ではこちらを優先しました。
##############################################################################
{
  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # Plasma6 は既定で Wayland セッションも選べるが、投影用途では X11 に固定する
  services.displayManager.defaultSession = "plasmax11";

  ############################################################################
  # SDDM のログイン画面 (greeter) 自体を Wayland ではなく Xorg で描画させる
  #
  # NixOS の sddm モジュールは既定で wayland.enable = true — つまり
  # ユーザーセッションを X11 に固定していても、ログイン画面はログイン前から
  # kwin_wayland (Wayland コンポジタ) で描画されます。この greeter は下の
  # deviceSection (Xorg 専用の BusID 指定) の対象外なので、出力先カードを
  # 固定したつもりでも、ログイン画面表示中だけ GPU 選択が Xorg のピン留めの
  # 外で行われ、実機で投影がガサガサになる不具合が起きました
  # (2026-08-11 実機確認、当時は GT1030 で発生)。greeter も Xorg にすることで、
  # ログイン画面からログイン後のセッションまで一貫して同じカードを使わせます。
  ############################################################################
  services.displayManager.sddm.wayland.enable = false;

  ############################################################################
  # HDMI 出力先カードの固定
  #
  # 実機の /sys/bus/pci/devices/*/uevent (PCI_SLOT_NAME) で確認した
  # 1660 SUPER の PCI アドレスは 0000:04:00.0 (bus 4, device 0, function 0)。
  # GT1030 撤去 (2026-08-12) に伴い、投影用の HDMI をこのカードに繋ぎ変えた。
  # 3060 Ti (bus 7) は計算専任のまま Xorg には出さない。
  ############################################################################
  services.xserver.deviceSection = ''
    BusID "PCI:4:0:0"
  '';

  ############################################################################
  # スリープ/ハイバネートの無効化
  #
  # KDE (PowerDevil) 導入後、アイドルやフタ閉じ経由でサスペンド/ハイバネートに
  # 入るようになった。このマシンはホームサーバーとして常時稼働が前提
  # (Minecraft・監視スタック・ローカル LLM・n8n など) なので、GUI があっても
  # スリープ機能自体を丸ごと止める。systemd のターゲットを無効化しておけば、
  # PowerDevil の設定値やアイドルタイムアウトに関係なく実行されなくなる。
  ############################################################################
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  # logind 側 (フタ閉じ・電源ボタン・アイドル) もサスペンドに倒さないようにする。
  # PowerDevil がこれらを上書きしうるため、上の systemd ターゲット無効化と
  # 合わせて二重に防ぐ。
  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchExternalPower = "ignore";
  services.logind.lidSwitchDocked = "ignore";
  services.logind.extraConfig = ''
    IdleAction=ignore
  '';
}
