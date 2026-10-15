#!/bin/bash
set -euo pipefail
id="sehl.tuple"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"
omarchy plugin disable "$id" || true
[[ -L $dest ]] && rm "$dest" && echo "removed $dest"
