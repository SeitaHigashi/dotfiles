{ config, lib, pkgs, ... }:

let
  m = import ./machine.nix;
in
{
  ############################################################################
  # ブートローダー
  #   ZFS + systemd-boot。/boot は SSD の EFI パーティション (vfat)。
  ############################################################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;   # /boot (1GiB) が溢れないように
  boot.loader.efi.canTouchEfiVariables = true;

  # /tmp は tmpfs ではなく rpool/tmp (disko/default.nix で定義) を使う。
  boot.tmp.useTmpfs = lib.mkDefault false;
  boot.tmp.cleanOnBoot = true;

  ############################################################################
  # ZFS 必須設定
  #   hostId は他マシンからの誤インポートを防ぐ識別子。
  #   install.sh が ISO 上の /etc/machine-id から生成して machine.nix に埋めます。
  #   インストール後は変更しないこと。
  ############################################################################
  networking.hostId = m.hostId;
  networking.hostName = m.hostName;
  # IP アドレス・DNS・NetworkManager の有無は modules/network.nix が持ちます。

  time.timeZone = "Asia/Tokyo";

  ############################################################################
  # ロケールとキーボード
  #
  # 表示言語は英語、キーボードは日本語配列。
  #   - エラーメッセージやログが英語になるので、検索・報告がしやすい
  #   - 記号の位置は物理キーボードどおり (@ [ ] : _ など)
  ############################################################################
  i18n.defaultLocale = "en_US.UTF-8";

  # 日本語ロケールも生成しておく。
  # これが無いと ja_JP.UTF-8 を要求するアプリで文字化けや警告が出ます。
  # 個別に日本語で使いたいときは  LANG=ja_JP.UTF-8 <command>  で切り替え可。
  i18n.supportedLocales = [
    "en_US.UTF-8/UTF-8"
    "ja_JP.UTF-8/UTF-8"
    "C.UTF-8/UTF-8"
  ];

  # 日付・通貨・紙サイズなど、言語とは別に地域依存の表示を日本にしたい場合は
  # 下のコメントを外してください (メッセージは英語のまま)。
  # i18n.extraLocaleSettings = {
  #   LC_TIME = "ja_JP.UTF-8";
  #   LC_MONETARY = "ja_JP.UTF-8";
  #   LC_PAPER = "ja_JP.UTF-8";
  # };

  # コンソール (TTY) のキーマップ: 日本語 106/109 配列
  console.keyMap = "jp106";

  # X / Wayland のキーボード配列: 日本語
  services.xserver.xkb.layout = "jp";

  ############################################################################
  # ユーザー
  ############################################################################
  users.users.${m.userName} = {
    isNormalUser = true;
    description = m.userDescription;
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPassword = m.userHashedPassword;
    openssh.authorizedKeys.keys = m.userSshKeys;
  };

  users.users.root = {
    hashedPassword = m.rootHashedPassword;
    # ISO で使った鍵を root にも引き継いでおく (復旧用)
    openssh.authorizedKeys.keys = m.userSshKeys;
  };

  # 鍵もパスワード認証も無い = SSH では入れない、という状態を検出して警告する。
  # (root パスワードは nixos-install の対話や passwd で /etc/shadow に直接
  #  設定できるため、コンソールログインまで不可能になるとは限らない)
  warnings = lib.optional (m.userSshKeys == [ ] && !m.allowPasswordAuth) ''
    machine.nix の userSshKeys が空で、かつ allowPasswordAuth = false です。
    このままでは SSH でログインできません (コンソールログインは可能)。
    エラーは "Permission denied (publickey,keyboard-interactive)" になります。
    passwd で設定したパスワードはコンソールと sudo にしか効きません。

    どちらかを行ってください:
      - userSshKeys に公開鍵を追加する (推奨)
      - allowPasswordAuth = true にする
  '';

  ############################################################################
  # Nix
  ############################################################################
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # /nix が HDD にある場合 GC は重い処理になるので定期実行に任せる。
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  ############################################################################
  # 基本パッケージ
  ############################################################################
  # neovim は modules/unstable.nix 経由で unstable から入ります。
  # ここに書くと stable 版と衝突するので、追加しないこと。
  environment.systemPackages = with pkgs; [
    vim        # initrd や単一ユーザーモードでの保険として残す
    git
    htop
    tmux
    pciutils
    usbutils
  ];
  # multica-cli は stable に無いため modules/unstable.nix 側で追加 (pkgs.unstable.multica-cli)。

  # sudoedit / systemctl edit / git commit などが nvim を使うようにする。
  environment.variables.EDITOR = "nvim";

  # `nix profile install` / `nix shell` など対話的な CLI 操作での unfree 許可。
  # システム全体のビルド (modules/gpu.nix の allowUnfreePredicate) とは別物 —
  # そちらは NVIDIA/n8n/open-webui など個別許可のみで、ここを true にしても
  # nixos-rebuild の評価には影響しません (nix コマンドが読む NIXPKGS_ALLOW_UNFREE
  # 環境変数と、モジュールの nixpkgs.config.allowUnfreePredicate は別経路のため)。
  environment.variables.NIXPKGS_ALLOW_UNFREE = "1";

  ############################################################################
  # SSH (インストール後も SSH で入る前提)
  ############################################################################
  services.openssh = {
    enable = true;
    settings = {
      # machine.nix の allowPasswordAuth で切り替え。
      # false のときは公開鍵 (userSshKeys) が唯一のログイン手段になります。
      PasswordAuthentication = m.allowPasswordAuth;

      # root はパスワードでは入れない。鍵があれば可 (復旧用)。
      # allowPasswordAuth = true にしても、ここは変えないこと。
      PermitRootLogin = "prohibit-password";
    };
  };

  ############################################################################
  # ハードウェアウォッチドッグ
  #
  # 2026-08-17、OOM でも高負荷でもなくカーネルログに一切エラーを残さないまま
  # 完全フリーズし、手動で電源断するまで復帰しなかった事例が発生 (原因未特定)。
  # 再発時に人手を介さず復帰できるよう、SP5100/SB800 TCO (AMD チップセット
  # 内蔵、sp5100_tco) を使う。ハードウェア検出で自動ロードされ /dev/watchdog
  # が既に存在するため、kernelModules への追記は不要 (起動ログで確認済み)。
  #
  # runtimeTime: systemd (PID1) がこの間隔で叩き続ける。PID1 ごと応答不能に
  #   なった場合だけ、この秒数後にハードウェアリセットがかかる。
  # rebootTime: reboot/shutdown 処理自体がハングした場合の保険。ZFS スレッドが
  #   blocked して shutdown が完走しない事例が過去にあった (disko/default.nix
  #   の dpool コメント参照) ため、無限に待たず強制リセットさせる。
  #   boot.zfs.forceImportRoot = true (modules/zfs.nix) 済みなので、
  #   強制リセット後に次回起動の import が失敗することはない。
  #   通常の shutdown (podman コンテナ停止・ZFS unmount 等) は数秒〜1分程度
  #   なので、余裕を見て 3分に設定 (誤検知でハードリセットしないため)。
  ############################################################################
  systemd.watchdog = {
    runtimeTime = "30s";
    rebootTime = "3min";
  };

  # 初回インストール時の NixOS バージョン。動作させ続ける限り変更しないこと。
  system.stateVersion = "25.05";
}
