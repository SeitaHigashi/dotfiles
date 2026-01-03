{ inputs, config, pkgs, ... }:
{
  wayland.windowManager.hyprland = {
    enable = true;
    package = null;
    portalPackage = null;
    # plugins =  with pkgs.hyprlandPlugins; [
    #   hyprscrolling
    # ];
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
        ",XF86AudioPrev,         exec, playerctl previous" # Audio previous button on keyboard
        ",XF86AudioPlay,         exec, playerctl play-pause" # Audio play/pause button on keyboard
        ",XF86AudioNext,         exec, playerctl next" # Audio next button on keyboard
        ",XF86AudioMute,         exec, wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" #  Audio mute button on keyboard
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
}
