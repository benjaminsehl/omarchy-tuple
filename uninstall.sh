#!/bin/bash
set -euo pipefail
id="sehl.tuple"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"
omarchy plugin disable "$id" || true
[[ -L $dest ]] && rm "$dest" && echo "removed $dest"
toggle="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr/tuple.lua"
if [[ -f $toggle ]]; then rm "$toggle"; hyprctl reload >/dev/null 2>&1 || true; echo "removed $toggle"; fi
