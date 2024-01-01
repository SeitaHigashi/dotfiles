#!/bin/bash

playerctl metadata -F -f '{{mpris:length}}::{{position}}' | while read -r line; do
    echo $line |
    awk -F '::' '{
      print "{\"length\": \"" $1/1000000 "\", \"position\": \"" $2/1000000 "\"}"
    }'
done
