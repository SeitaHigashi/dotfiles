{ inputs, config, pkgs, lib, osConfig, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "seita";
  home.homeDirectory = "/home/seita";

  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  home.stateVersion = "25.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    pkgs.neovim

    # Useful utilities and Neovim dependencies
    pkgs.gcc
    pkgs.nodejs_22
    pkgs.ripgrep

    # Useful utilities
    pkgs.tmux
    pkgs.bat
    pkgs.trash-cli
    pkgs.lsof
    pkgs.unzip
    pkgs.wget
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  gtk = {
    enable = true;
    theme = {
      package = pkgs.tokyonight-gtk-theme;
      name = "Tokyonight-Dark";
      # package = pkgs.nightfox-gtk-theme;
      # name = "Nightfox-Dark-hdpi";
    };
  };

  imports = [ ./wm/hyprland.nix ];

  programs.git = {
    enable = true;
    settings = {
      init = {
        defaultBranch = "main";
      };
      user = {
        name = "Seita Higashi";
        email = "higashi110902@gmail.com";
      };
    };
  };

  programs.gh = {
    enable = true;
  };

  programs.zellij = {
    enable = true;
    #enableBashIntegration = true;
    #attachExistingSession = true;
    #exitShellOnExit = true;
    settings = {
      pane_frames = false;
      simplified_ui = true;
      default_mode = "locked";
      show_startup_tips = false;
    };
  };

  programs.tmux = {
    enable = true;
    plugins = with pkgs; [
      tmuxPlugins.sensible
    ];
    extraConfig = ''
      if "ls ~/.local/share/nvim/lazy/nightfox.nvim/extra/nordfox/nordfox.tmux" \
        "source-file ~/.local/share/nvim/lazy/nightfox.nvim/extra/nordfox/nordfox.tmux"

      set -g status-left "#[fg=#232831,bg=#81a1c1,bold] #S #[fg=#81a1c1,bg=#232831,nobold,nounderscore,noitalics]"
      
      set -g status-right "#[fg=#232831,bg=#232831,nobold,nounderscore,noitalics]#[fg=#81a1c1,bg=#232831] #{prefix_highlight} #[fg=#abb1bb,bg=#232831,nobold,nounderscore,noitalics]#[fg=#232831,bg=#abb1bb] %Y-%m-%d  %I:%M %p #[fg=#81a1c1,bg=#abb1bb,nobold,nounderscore,noitalics]#[fg=#232831,bg=#81a1c1,bold] #h "
      
      setw -g window-status-current-format "#[fg=#232831,bg=#abb1bb,nobold,nounderscore,noitalics]#[fg=#232831,bg=#abb1bb,bold] #I  #W #F #[fg=#abb1bb,bg=#232831,nobold,nounderscore,noitalics]"
      
      setw -g window-status-format "#[fg=#232831,bg=#232831,nobold,nounderscore,noitalics]#[default] #I  #W #F #[fg=#232831,bg=#232831,nobold,nounderscore,noitalics]"
      bind -r h select-pane -L
      bind -r j select-pane -D
      bind -r k select-pane -U
      bind -r l select-pane -R
      
      bind -r H split-window -hb
      bind -r J split-window -v
      bind -r K split-window -vb
      bind -r L split-window -h
    '';
  };

  programs.bash = {
    enable = true;
    shellAliases = {
      rm = "trash-put";
    };
  };

  programs.starship = {
    enable = true;
  };

  programs.fzf.enable = true;

  programs.zoxide = {
    enable = true;
    options = ["--cmd cd"];
  };

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
    nix-direnv.enable = true;
  };

  programs.wezterm = {
    enable = true;
    extraConfig = builtins.readFile ../wezterm/wezterm.lua;
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
