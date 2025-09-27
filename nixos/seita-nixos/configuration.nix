{ config, pkgs, ... }:

let
  kubeMasterIP = "192.168.11.220";
  kubeMasterHostname = "api.kube";
  kubeMasterAPIServerPort = 6443;
in {
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];
  
  # Enable Bluetooh
  hardware.enableRedistributableFirmware = true;

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  hardware.bluetooth = {
    # package = pkgs.bluez5-experimental;
    # settings.Policy.AutoEnable = "true";
    # settings.General.Enable = "Source,Sink,Media,Socket";
  };

  # services.blueman.enable = true;

  # Enable OpenGL
  hardware.opengl.enable = true;

  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = ["nvidia"];

  hardware.nvidia = {

    # Modesetting is required.
    modesetting.enable = true;

    # Nvidia power management. Experimental, and can cause sleep/suspend to fail.
    powerManagement.enable = false;

    # Fine-grained power management. Turns off GPU when not in use.
    # Experimental and only works on modern Nvidia GPUs (Turing or newer).
    powerManagement.finegrained = false;

    # Use the NVidia open source kernel module (not to be confused with the
    open = false;

    # Enable the Nvidia settings menu,
    nvidiaSettings = true;

    # Optionally, you may need to select the appropriate driver version for your specific GPU.
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.plymouth.enable = true;
  # boot.kernelPackages = pkgs.linuxPackages_zen;

  # enable KSM(Kernel Samepage Merging)
  hardware.ksm.enable = true;

  networking.hostName = "seita-nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Enable networking
  networking.networkmanager = {
    enable = true;
    ensureProfiles.profiles.enp6s18 = {
      connection = {
        id = "enp6s18";
        type = "ethernet";
        autoconnect = true;
        autoconnect-priority = 100;
        autoconnect-retries = 5;
      };
      ipv4 = {
        method = "manual";
        addresses = "192.168.11.251/24";
        gateway = "192.168.11.1";
        dns = "192.168.11.252";
      };
      ipv6 = {
        method = "auto";
      };
      ethernet.mac-address="bc:24:11:9e:fb:80";
    };
  };

  # Set your time zone.
  time.timeZone = "Asia/Tokyo";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ja_JP.UTF-8";
    LC_IDENTIFICATION = "ja_JP.UTF-8";
    LC_MEASUREMENT = "ja_JP.UTF-8";
    LC_MONETARY = "ja_JP.UTF-8";
    LC_NAME = "ja_JP.UTF-8";
    LC_NUMERIC = "ja_JP.UTF-8";
    LC_PAPER = "ja_JP.UTF-8";
    LC_TELEPHONE = "ja_JP.UTF-8";
    LC_TIME = "ja_JP.UTF-8";
  };

  i18n.inputMethod = {
    enabled = "fcitx5";
    fcitx5.addons = with pkgs; [
      fcitx5-mozc
      fcitx5-gtk
    ];
  };

  fonts.packages = [
  	pkgs.noto-fonts-cjk-sans
  ];

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
    resolutions = [{
      x = 1920;
      y = 1080;
    }];
  };

  # Enable the KDE Plasma Desktop Environment.
  services.displayManager.sddm.enable = true;
  services.xserver.desktopManager.plasma5.enable = true;

  services.xrdp.enable = true;
  services.xrdp.defaultWindowManager = "startplasma-x11";
  services.xrdp.openFirewall = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "jp";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "jp106";

  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.seita = {
    isNormalUser = true;
    description = "seita";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      brave
      hypnotix
    ];
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    pulseeffects-legacy
    discover
    ffmpeg
    neovim

    # for kubernetes
    kompose
    kubectl
    kubernetes

  ];

  # Enable nix command and flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Nix store garbage collection
  nix.gc = {
    automatic = true;
    dates = "daily";
    options = "--delete-older-than 14d";
  };

  # Nix store optimisation
  nix.optimise.automatic = true;
  nix.settings.auto-optimise-store = true;

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "yes";
    X11Forwarding = true;
  };

  # QEmu Guest Agent
  services.qemuGuest.enable = true;

  # Tailscale
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
    extraSetFlags = [
      "--advertise-exit-node"
      "--advertise-routes=192.168.11.0/24"
      #"--advertise-node-allow-lan-access"
    ];
  };

  # Ollama
  services.ollama = {
    enable = true;
    acceleration = "cuda";
    host = "[::]";
  };


  # services.postgresql = {
  #   enable = false;
  #   ensureDatabases = [ "open-webui" ];
  #   enableTCPIP = true;
  #   authentication = pkgs.lib.mkOverride 10 ''
  #     #type database DBuser origin-address auth-method
  #     local all all trust
  #     #host all all 127.0.0.1/32 trust
  #     host all all ::1/128 trust
  #   '';
  # };

  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers = {
    backend = "podman";
    containers.homeassistant = {
      volumes = [ "home-assistant:/config" ];
      environment.TZ = "Tokyo/Asia";
      image = "ghcr.io/home-assistant/home-assistant:stable"; # Warning: if the tag does not change, the image will not be updated
      extraOptions = [ 
        "--network=host" 
      ];
    };

    containers.open-webui = {
      volumes = [ "open-webui:/app/backend/data" ];
      environment.TZ = "Tokyo/Asia";
      image = "ghcr.io/open-webui/open-webui:cuda";
      labels = {
        "io.containers.autoupdate" = "registry";
      };
      extraOptions = [ 
        "--network=host" 
        "--device=nvidia.com/gpu=all"
      ];
    };

    # containers.siyuan = {
    #   volumes = [ "siyuan:/siyuan" ];
    #   environment.TZ = "Tokyo/Asia";
    #   environment.PUID = "0";
    #   environment.PGID = "0";
    #   image = "docker.io/b3log/siyuan";
    #   labels = {
    #     "io.containers.autoupdate" = "image";
    #   };
    #   extraOptions = [
    #     "--network=host"
    #   ];
    #   workdir="/siyuan";
    # };

    containers.stable-diffusion-webui = {
      volumes = [ "stable-diffusion:/app/stable-diffusion-webui"];
      environment.TZ = "Tokyo/Asia";
      image = "docker.io/universonic/stable-diffusion-webui";
      ports = [ "8888:8080" ];
      extraOptions = [ 
        "--device=nvidia.com/gpu=all"
      ];
      environment = {
        COMMANDLINE_ARGS = "--api";
      };
    };

    containers.open-webui-pipelines = {
      volumes = [ "open-webui-pipelines:/app/pipelines"];
      environment.TZ = "Tokyo/Asia";
      image = "ghcr.io/open-webui/pipelines:main";
      ports = [ "9099:9099" ];
      environment = {
        #PIPELINES_URL = "https://github.com/open-webui/pipelines/blob/main/examples/filters/detoxify_filter_pipeline.py";
      };
    };
  };

  # FlatPak
  services.flatpak.enable = true;

  # SW settings

  programs.nix-ld.enable = true;

  # Set Neovim as default editor
  # programs.neovim = {
  #   enable = true;
  #   defaultEditor = true;
  #   vimAlias = true;
  #   viAlias = true;
  # };

  # Git
  programs.git.enable = true;

  # Nano
  programs.nano.enable = false;

  #
  programs.firefox.enable = true;

  programs.kdeconnect.enable = true;

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [
  #   11434
  #   8123
  #   8080
  #   6443
  # ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  networking.firewall.enable = false;

  # For kubernetes settings
  # resolve master hostname
  networking.extraHosts = "${kubeMasterIP} ${kubeMasterHostname}";

  services.kubernetes = let
    api = "https://${kubeMasterHostname}:${toString kubeMasterAPIServerPort}";
  in
  {
    roles = ["node"];
    masterAddress = kubeMasterHostname;
    easyCerts = true;

    # point kubelet and other services to kube-apiserver
    kubelet.kubeconfig.server = api;
    apiserverAddress = api;

    # use coredns
    addons.dns.enable = true;

    # needed if you use swap
    kubelet.extraOpts = "--fail-swap-on=false";
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
}

