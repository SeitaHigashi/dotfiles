{ inputs, config, pkgs, ... }:
{
  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;
    plugins = [
      inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprexpo
      # inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprscrolling
    ];
    settings = {
      plugin = {
        hyprexpo = {
          columns = 3;
          workspace_method = "first 1";
        };
      };
      "$mod" = "SUPER";
      bind = [
        "$mod SHIFT, Q, killactive, "
        "$mod, M, exit, "
        "$mod SHIFT,  F, togglefloating, "
        "$mod, F, fullscreen, "
        "$mod, P, pin,"
        "$mod, D, exec, hyprlauncher"
        # "$mod, return, exec, alacritty"
        "$mod, return, exec, wezterm"
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
        "$mod CTRL, S, togglespecialworkspace, spotify"
        "$mod CTRL, D, togglespecialworkspace, discord"
        "$mod, g, hyprexpo:expo, toggle"
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
        ",XF86AudioPrev,         exec, playerctl previous" # Audio previous button on keyboard
        ",XF86AudioPlay,         exec, playerctl play-pause" # Audio play/pause button on keyboard
        ",XF86AudioNext,         exec, playerctl next" # Audio next button on keyboard
        ",XF86AudioMute,         exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" #  Audio mute button on keyboard
        # Move to next/previous window
        # Change focused window and change z-order
        "$mod, TAB, cyclenext"
        "$mod, TAB, alterzorder, top"
        "$mod SHIFT, TAB, cyclenext, prev"
        "$mod SHIFT, TAB, alterzorder, top"
        "ALT, TAB, cyclenext"
        "ALT, TAB, alterzorder, top"
        "ALT SHIFT, TAB, cyclenext, prev"
        "ALT SHIFT, TAB, alterzorder, top"
      ];

      bindm = [
        # Move/resize windows with mainMod + LMB/RMB and dragging
        "$mod, mouse:272, movewindow"
        "$mod, mouse:273, resizewindow"
      ];

      binde = [
        ",XF86MonBrightnessDown, exec, brightnessctl s 5%-" # Brightness down button on keyboard
        ",XF86MonBrightnessUp,   exec, brightnessctl s 5%+" # Brightness up button on keyboard
        ",XF86KbdBrightnessDown, exec, brightnessctl -d smc::kbd_backlight s 10%-" # Keyboard brightness down button on keyboard
        ",XF86KbdBrightnessUp,   exec, brightnessctl -d smc::kbd_backlight s 10%+" # Keyboard brightness up button on keyboard

        ",XF86AudioRaiseVolume, exec, wpctl set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 1%+" # Audio volume up button on keyboard
        ",XF86AudioLowerVolume, exec, wpctl set-volume @DEFAULT_AUDIO_SINK@ 1%-" # Audio volume down button on keyboard

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
          border_size = 1;
          "col.active_border" = "0xff999999";
          layout = "dwindle";
          # layout = "scrolling";
      };
      decoration = {
          rounding = 4;
          blur.size = 6;
          shadow.enabled = false;
          dim_inactive = true;
          dim_strength = 0.05;
      };

      misc = {
        focus_on_activate = true ;
      };

      exec-once = [
        "fcitx5 -d -r"
        "fcitx5-remote -r"
        "hyprpanel"
        "discord --silent"
        "spotify"
        "tailscale systray"
      ];

      windowrule = [
      # General rules
        "match:class .*, float on, size 1100 700, center on"
        # If tiled windows are opened on the workspace, new window will be opened as tiled
        "match:workspace w[t2-99], float off"

      # Picture in picture rule
        "match:title (Picture\\s+in\\s+picture), pin on, size 320 180, border_size 0, float on, move (monitor_w-320-8) (monitor_h-180-8)"

      # Special workspace rules
        "match:class Spotify, float off, workspace special:spotify silent, border_size 0, suppress_event activate fullscreen fullscreenoutput maximize"
        "match:class discord, float off, workspace special:discord silent, border_size 0"
      ];

      animation = [
        "specialWorkspace, 1, 8, default, slidefadevert"
      ];

      gesture = [
        "3, horizontal, workspace"
        "3, down, special, discord"
        "3, up, special, spotify"
        "4, swipe, move"
        "3, pinch, fullscreen"
        "4, pinch, fullscreen"
      ];
    };
  };
}
