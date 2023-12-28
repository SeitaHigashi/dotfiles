#!/bin/bash

# If player is not running, return empty string
if ! playerctl status &>/dev/null; then
    exit
fi

echo -n "$(playerctl metadata artist) - $(playerctl metadata title)"
