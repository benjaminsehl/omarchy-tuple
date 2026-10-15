#!/bin/bash
# Link this folder into the Omarchy shell plugin directory and add the widget
# to the bar. Re-running is safe.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id="sehl.tuple"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"

mkdir -p "$(dirname "$dest")"
if [[ -L $dest ]]; then
  ln -sfn "$here" "$dest"
elif [[ -e $dest ]]; then
  echo "install: $dest exists and is not a symlink; leaving it alone" >&2
  exit 1
else
  ln -s "$here" "$dest"
fi
echo "linked $dest -> $here"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1
omarchy plugin enable "$id" "${@:---section right}"
echo "enabled $id"
