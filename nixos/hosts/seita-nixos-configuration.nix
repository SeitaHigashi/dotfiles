{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./seita-nixos-hardware-configuration.nix
      ../commons/commons.nix
      ../commons/i18n.nix
      ../commons/applications.nix
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
  hardware.graphics.enable = true;

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
  services.displayManager.sddm.wayland.enable = true;
  services.desktopManager.plasma6.enable = true;

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

  # Enable sound with pipewire.
  # hardware.pulseaudio.enable = false;
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.seita = {
    isNormalUser = true;
    description = "seita";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      hypnotix
    ];
  };

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # pulseeffects-legacy
    kdePackages.discover
    ffmpeg

    # for kubernetes
    kubectl
  ];

  # List services that you want to enable:

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
    # acceleration = "cuda";
    host = "[::]";
  };

  # Nvidia GPU exporter for prometheus
  services.prometheus.exporters = {
    nvidia-gpu = {
      enable = true;
      openFirewall = true;
      listenAddress = "192.168.11.251";
    };
  };

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

  # SW settings

  programs.firefox.enable = true;

  programs.kdeconnect.enable = true;

  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };

  networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.05"; # Did you read the comment?
}

