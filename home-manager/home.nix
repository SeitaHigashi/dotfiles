{ inputs, config, pkgs, ... }:

{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "seita";
  home.homeDirectory = "/home/seita";

  nixpkgs.config.allowUnfree = true;
  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    pkgs.nodejs_22
    pkgs.gcc
    pkgs.ripgrep
    pkgs.tmux
    pkgs.bat
    pkgs.trash-cli
    pkgs.neovim
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  home.sessionVariables = {
    EDITOR = "nvim";
  };

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

  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;
    plugins =  with pkgs.hyprlandPlugins; [
      hyprscrolling
    ];
    settings = {
      "$mod" = "SUPER";
      bind = [
        "$mod SHIFT, Q, killactive, "
        "$mod, M, exit, "
        "$mod SHIFT,  F, togglefloating, "
        "$mod, F, fullscreen, "
        "$mod, P, pseudo,"
        "$mod, D, exec, hyprlauncher"
        "$mod, return, exec, alacritty"
        # Move focus with mod + arrow keys
        "$mod, left, movefocus, l"
        "$mod, right, movefocus, r"
        "$mod, up, movefocus, u"
        "$mod, down, movefocus, d"
        "$mod, H, movefocus, l"
        "$mod, L, movefocus, r"
        "$mod, K, movefocus, u"
        "$mod, J, movefocus, d"
        "$mod SHIFT, H, movewindow, l"
        "$mod SHIFT, L, movewindow, r"
        "$mod SHIFT, K, movewindow, u"
        "$mod SHIFT, J, movewindow, d"
        # Switch workspaces with mod + [0-9]
        "$mod, 1, workspace, 1"
        "$mod, 2, workspace, 2"
        "$mod, 3, workspace, 3"
        "$mod, 4, workspace, 4"
        "$mod, 5, workspace, 5"
        "$mod, 6, workspace, 6"
        "$mod, 7, workspace, 7"
        "$mod, 8, workspace, 8"
        "$mod, 9, workspace, 9"
        "$mod, 0, workspace, 10"
        "$mod SHIFT, S, movetoworkspace, special"
        "$mod, S, togglespecialworkspace,"
        "$mod, TAB, layoutmsg, cyclenext"
        "$mod, TAB, layoutmsg, swapwithmaster master"
        # Move active window to a workspace with mod + SHIFT + [0-9]
        "$mod SHIFT, 1, movetoworkspace, 1"
        "$mod SHIFT, 2, movetoworkspace, 2"
        "$mod SHIFT, 3, movetoworkspace, 3"
        "$mod SHIFT, 4, movetoworkspace, 4"
        "$mod SHIFT, 5, movetoworkspace, 5"
        "$mod SHIFT, 6, movetoworkspace, 6"
        "$mod SHIFT, 7, movetoworkspace, 7"
        "$mod SHIFT, 8, movetoworkspace, 8"
        "$mod SHIFT, 9, movetoworkspace, 9"
        "$mod SHIFT, 0, movetoworkspace, 10"
        # Scroll through existing workspaces with mod + scroll
        "$mod, mouse_down, workspace, e+1"
        "$mod, mouse_up, workspace, e-1"
      ];

      bindm = [
        # Move/resize windows with mainMod + LMB/RMB and dragging
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

      input = {
          kb_layout = "jp";
          follow_mouse = 1;
          touchpad = {
              natural_scroll = "yes";
              clickfinger_behavior = true;
          };
          sensitivity = 0; # -1.0 - 1.0, 0 means no modification.
      };

      general = {
          gaps_in = 3;
          gaps_out = 3;
          border_size = 2;
          # col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg;
          # col.inactive_border = rgba(595959aa);
          # layout = dwindle;
      };
      decoration = {
          rounding = 5;
      };
      exec-once = [
        "fcitx5"
        "hyprpanel"
      ];
    };

  };

  programs.hyprpanel = {
    enable = true;
    # package = inputs.hyprpanel.packages.${pkgs.system}.default;
    settings = {
      bar.workspaces.show_icons = true;
      general.scailingpriority = "hyprland";
    };
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
