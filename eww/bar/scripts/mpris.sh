#!/bin/bash

# Output metadata as json format using awk
playerctl metadata -F -f '{{playerName}}::{{title}}::{{artist}}::{{mpris:artUrl}}::{{status}}' | while read -r line; do
#     echo $line |
#     awk -F '::' '{
#       command = "wget -O /tmp/art.jpg " $4;
#       system(command);
#       system("eww reload -c ~/.config/eww/music");
#     }' &
    echo $line |
    awk -F '::' '{
      print "{\"name\": \"" $1 "\", \"title\": \"" $2 "\", \"artist\": \"" $3 "\", \"artUrl\": \"" $4 "\", \"status\": \"" $5 "\"}"
    }'
done
