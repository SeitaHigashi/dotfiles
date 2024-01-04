#!/bin/bash

if [ -f /tmp/volumectl.lock ]; then
  touch /tmp/volumectl.new.lock
  pactl set-sink-volume @DEFAULT_SINK@ +$1%
  
  current=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -Po "[0-9]+%" | head -1 | grep -Po "[0-9]+")
  eww update volume=$current
  exit 0
fi

touch /tmp/volumectl.lock

eww open notify_volume
pactl set-sink-volume @DEFAULT_SINK@ +$1%

current=$(pactl get-sink-volume @DEFAULT_SINK@ | grep -Po "[0-9]+%" | head -1 | grep -Po "[0-9]+")
eww update volume=$current

loop=2
while (($loop>0)); do
  if [ -f /tmp/volumectl.new.lock ]; then
    rm /tmp/volumectl.new.lock
    loop=2
  fi
  loop=$((loop-1))
  sleep 1
done

rm /tmp/volumectl.lock

eww close notify_volume


