{ config, lib, pkgs, ... }:

let
  m = import ./machine.nix;
in
{
  ############################################################################
  # Bootloader
  #   ZFS + systemd-boot. /boot is the SSD's EFI partition (vfat).
  ############################################################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;   # keep /boot (1GiB) from filling up
  boot.loader.efi.canTouchEfiVariables = true;

  # /tmp uses rpool/tmp (defined in disko/default.nix), not tmpfs.
  boot.tmp.useTmpfs = lib.mkDefault false;
  boot.tmp.cleanOnBoot = true;

  ############################################################################
  # Required ZFS settings
  #   hostId prevents accidental pool import from another machine. Generated
  #   by install.sh from the ISO's /etc/machine-id into machine.nix. Do not
  #   change after install.
  ############################################################################
  networking.hostId = m.hostId;
  networking.hostName = m.hostName;
  # IP address, DNS, and whether NetworkManager is used live in modules/network.nix.

  time.timeZone = "Asia/Tokyo";

  ############################################################################
  # Locale and keyboard
  #
  # Display language is English, keyboard layout is Japanese.
  #   - error messages and logs stay in English, easier to search/report
  #   - symbol positions match the physical keyboard (@ [ ] : _ etc.)
  ############################################################################
  i18n.defaultLocale = "en_US.UTF-8";

  # Also generate the Japanese locale.
  # Without it, apps that require ja_JP.UTF-8 show mojibake or warnings.
  # To use Japanese for a single command: LANG=ja_JP.UTF-8 <command>
  i18n.supportedLocales = [
    "en_US.UTF-8/UTF-8"
    "ja_JP.UTF-8/UTF-8"
    "C.UTF-8/UTF-8"
  ];

  # To use Japan-local formatting for dates/currency/paper size while keeping
  # messages in English, uncomment below.
  # i18n.extraLocaleSettings = {
  #   LC_TIME = "ja_JP.UTF-8";
  #   LC_MONETARY = "ja_JP.UTF-8";
  #   LC_PAPER = "ja_JP.UTF-8";
  # };

  # Console (TTY) keymap: Japanese 106/109 layout
  console.keyMap = "jp106";

  # X / Wayland keyboard layout: Japanese
  services.xserver.xkb.layout = "jp";

  ############################################################################
  # Users
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
    # Carry the key used on the ISO over to root as well (for recovery)
    openssh.authorizedKeys.keys = m.userSshKeys;
  };

  # Warn if there's no key and no password auth, i.e. SSH login is impossible.
  # (root's password can still be set directly in /etc/shadow via nixos-install's
  #  prompt or `passwd`, so this doesn't necessarily mean console login is dead too.)
  warnings = lib.optional (m.userSshKeys == [ ] && !m.allowPasswordAuth) ''
    machine.nix's userSshKeys is empty and allowPasswordAuth = false.
    SSH login is not possible as configured (console login still is).
    The error will be "Permission denied (publickey,keyboard-interactive)".
    A password set via passwd only works for console and sudo.

    Do one of:
      - add a public key to userSshKeys (recommended)
      - set allowPasswordAuth = true
  '';

  ############################################################################
  # Nix
  ############################################################################
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };

  # GC is heavy when /nix is on HDD, so leave it to the periodic schedule.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  ############################################################################
  # Base packages
  ############################################################################
  # neovim comes from unstable via modules/unstable.nix.
  # Do not add it here — it would conflict with the stable version.
  environment.systemPackages = with pkgs; [
    vim        # kept as a fallback for initrd / single-user mode
    git
    htop
    tmux
    pciutils
    usbutils
  ];
  # multica-cli isn't in stable, so it's added via modules/unstable.nix (pkgs.unstable.multica-cli).

  # Make sudoedit / systemctl edit / git commit etc. use nvim.
  environment.variables.EDITOR = "nvim";

  # Unfree allowance for interactive CLI use (`nix profile install` / `nix shell`).
  # Separate from the whole-system build's allowance
  # (modules/unfree.nix's allowUnfreePredicate, individual packages only) —
  # setting this to true doesn't affect nixos-rebuild's evaluation, since the
  # NIXPKGS_ALLOW_UNFREE env var (read by nix commands) and the module's
  # nixpkgs.config.allowUnfreePredicate are separate code paths.
  environment.variables.NIXPKGS_ALLOW_UNFREE = "1";

  ############################################################################
  # SSH (assumes SSH access after install too)
  ############################################################################
  services.openssh = {
    enable = true;
    settings = {
      # Toggled via machine.nix's allowPasswordAuth.
      # When false, the public key (userSshKeys) is the only way to log in.
      PasswordAuthentication = m.allowPasswordAuth;

      # root cannot log in with a password. Key-based root login is allowed
      # (for recovery). Do not change this even if allowPasswordAuth = true.
      PermitRootLogin = "prohibit-password";
    };
  };

  ############################################################################
  # Hardware watchdog
  #
  # 2026-08-17: the host froze completely with no OOM, no high load, and no
  # error in the kernel log, and did not recover until manually power-cycled
  # (root cause unidentified). To recover unattended if this recurs, this uses
  # SP5100/SB800 TCO (built into the AMD chipset, sp5100_tco). It's
  # auto-loaded by hardware detection and /dev/watchdog already exists, so no
  # kernelModules entry is needed (confirmed via boot log).
  #
  # runtimeTime: systemd (PID1) pets the watchdog at this interval. A hardware
  #   reset only fires if PID1 itself stops responding for this long.
  # rebootTime: fallback for a hung reboot/shutdown itself. ZFS threads have
  #   blocked shutdown from completing before (see the dpool comment in
  #   disko/default.nix), so this forces a reset rather than waiting forever.
  #   Safe to force-reset because boot.zfs.forceImportRoot = true
  #   (modules/zfs.nix) is already set, so import won't fail on next boot.
  #   Normal shutdown (stopping podman containers, ZFS unmount, etc.) takes
  #   seconds to about a minute, so 3 minutes leaves margin against false
  #   positives triggering a hard reset.
  ############################################################################
  systemd.watchdog = {
    runtimeTime = "30s";
    rebootTime = "3min";
  };

  # NixOS version at first install. Do not change while this system keeps running.
  system.stateVersion = "25.05";
}
