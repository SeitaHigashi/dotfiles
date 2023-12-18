#! /bin/bash

hyprland () {
  #hyprctl workspaces -j | jq '[.[] | select(.id > 0) | .id | tostring | "(label :text \"hello\")" ]'
  workspace="(box :orientation \"h\""
for i in {1..9}; do
  workspace+="(button :onclick \"hyprctl dispatch workspace $i\"  \"$i\")"
done
workspace+=")"
echo $workspace
}

socat -u UNIX-CONNECT:/tmp/hypr/"$HYPRLAND_INSTANCE_SIGNATURE"/.socket2.sock - | while read -r; do 
hyprland
done
