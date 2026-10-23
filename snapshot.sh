#!/bin/bash

# Captures each output for the lock screen intro and prints, per monitor, the
# windows visible on it, so the lock view can cut them out of the snapshot and
# animate them away while the wallpaper stays put.
#
# Usage: snapshot.sh <dir> <output>...

umask 077
dir="$1"
shift
rm -rf "$dir"
mkdir -p "$dir" || exit 1

windows=$(jq -n \
  --argjson monitors "$(hyprctl -j monitors)" \
  --argjson clients "$(hyprctl -j clients)" \
  --argjson border "$(hyprctl -j getoption general:border_size | jq '.int // 0')" \
  --argjson rounding "$(hyprctl -j getoption decoration:rounding | jq '.int // 0')" '
  {
    border: $border,
    rounding: $rounding,
    monitors: (reduce $monitors[] as $m ({};
      .[$m.name] = (
        [
          $clients[]
          | select(.mapped and (.hidden | not))
          | select(.workspace.id == $m.activeWorkspace.id
              or ($m.specialWorkspace.id != 0 and .workspace.id == $m.specialWorkspace.id)
              or (.pinned and .monitor == $m.id))
          | {
              x: (.at[0] - $m.x),
              y: (.at[1] - $m.y),
              w: .size[0],
              h: .size[1],
              floating: .floating,
              fullscreen: (.fullscreen > 0)
            }
        ]
        # A fullscreen window hides everything under it on that monitor.
        | if any(.fullscreen) then map(select(.fullscreen)) else sort_by(.floating) end
      )))
  }') || windows='{}'

for output in "$@"; do
  timeout 1 grim -t ppm -o "$output" "$dir/$output.ppm" &
done
wait

printf '%s\n' "$windows"
