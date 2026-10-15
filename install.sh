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

# Hyprland rules (peer webcams as a floating PiP, Tuple dialogs floated),
# loaded the same way Omarchy loads its own toggles.
toggles="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/toggles/hypr"
mkdir -p "$toggles"
printf -- '-- Written by omarchy-tuple install.sh.\ndofile([[%s/hypr/tuple.lua]])\n' "$here" > "$toggles/tuple.lua"
if command -v hyprctl >/dev/null; then
  hyprctl reload >/dev/null
  errors="$(hyprctl configerrors 2>/dev/null | sed '/^\s*$/d')"
  if [[ -n $errors ]]; then
    rm -f "$toggles/tuple.lua"; hyprctl reload >/dev/null
    echo "install: Hyprland rejected hypr/tuple.lua, rules not installed:" >&2
    echo "$errors" >&2
  else
    echo "installed Hyprland rules ($toggles/tuple.lua)"
  fi
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 1
omarchy plugin enable "$id" "${@:---section right}"
echo "enabled $id"
