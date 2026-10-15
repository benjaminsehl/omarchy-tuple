# Tuple for Omarchy

A native Omarchy shell bar widget and panel for the
[Tuple Linux client](https://tuple.app/linux/) (alpha, v2026_09_16.1), built
with the same Quickshell UI kit as the built-in Tailscale, Bluetooth, and Audio
panels, so it follows your theme, fonts, borders, and keyboard conventions.

- **Bar icon:** Tuple's mark drawn in theme colours. It is dimmed with a slash
  when Tuple is off, shows a red badge when you're logged out, turns the
  "active" colour during a call (darker when muted), gets a dot while you share
  your screen, and pulses on an incoming call.
- **Panel:**
  - an on/off switch for the daemon
  - browser login with an auth-code field
  - new call (copies your link)
  - join a call from a pasted link or straight from the clipboard
  - in-call controls: mute, share, camera, copy link, end
  - who's in the call and who's sharing
  - favourites and available teammates, with search across the whole org
    directory, a ★ toggle, and one-click calling
  - all `tuple settings`
  - a shortcut to Tuple's own window, and log out
- **Notifications:** you get a desktop notification for incoming calls.

## Webcams

- **Their webcam:** it shows as a floating picture-in-picture in the
  bottom-right corner. It stays on every workspace, never steals focus, and
  keeps its shape when resized. Drag it with `SUPER` + left mouse and resize it
  with `SUPER` + right mouse. The rule is in `hypr/tuple.lua`, which also
  floats and centres Tuple's small prompts (incoming call, join request,
  errors).
- **Your webcam:** Tuple for Linux can't send webcam video yet. In
  v2026_09_16.1 the capture code is still a TODO (`WebcamCapturerAdapter:
  TODO: implement Start`), and there's no command for it. Until it ships, the
  **Camera** button (`v`) opens Omarchy's own floating camera overlay, the one
  `omarchy capture screenrecording --with-webcam` uses. Your peer sees you
  whenever you share your screen. The overlay closes when the call ends.
  - **Settings:** `cameraDevice` (blank uses the first camera from
    `omarchy-capture-webcam-list`), `cameraSize` (`small`/`medium`/`large`),
    and `cameraFollowsCall`.

## Install

```bash
./install.sh            # symlinks into ~/.config/omarchy/plugins/sehl.tuple, adds it to the bar,
                        # and loads hypr/tuple.lua via ~/.local/state/omarchy/toggles/hypr/tuple.lua
./uninstall.sh          # undoes all three
```

Pass a placement to `install.sh`, e.g. `./install.sh --section right --before omarchy.agents`.

The shell's plugin watcher doesn't follow symlinks. After editing, run
`./install.sh` again: re-creating the link triggers a reload. If the IPC
functions seem stale, the old handler kept the target; run `omarchy restart shell`.

## Use

| Bar | Action |
|---|---|
| left click | open the panel |
| right click | in a call: mute/unmute · ringing: answer |
| middle click | in a call: share/unshare · otherwise: refresh |

In the panel, `j`/`k` or the arrow keys move, and `enter`/`space` activates the
selected row. Other keys:

| Key | Action |
|---|---|
| `m` | mute |
| `s` | share |
| `v` | camera overlay |
| `e` | end or decline |
| `a` | answer |
| `n` | new call |
| `i` | join field |
| `c` | copy call link |
| `/` | search people |
| `f` | favourite the selected person |
| `o` | daemon on/off |
| `r` | refresh |
| `tab` | next panel |
| `esc` | close |

### IPC and keybindings

```bash
omarchy-shell sehl.tuple toggle | toggleMute | toggleShare | toggleCamera | end | newCall | joinClipboard | copyLink | on | off
omarchy-shell sehl.tuple join https://tuple.app/c/xyz
omarchy-shell sehl.tuple status        # JSON: daemon, loggedIn, call, peers, muted, sharing, …
omarchy-shell sehl.tuple demo call     # canned UI states: call | idle | incoming | login | off (back to live)
```

Example Hyprland bindings (not installed for you), in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + T", "Tuple panel", "omarchy-shell sehl.tuple toggle")
o.bind("SUPER + CTRL + M", "Tuple mute", "omarchy-shell sehl.tuple toggleMute")
```

## How the Tuple Linux client works

These findings come from capturing traffic on the CLI's socket and from the
binary's strings. They are the basis of `Model.js`.

- **Thin CLI:** `tuple` is one static binary. Each invocation is a thin
  client: it connects to the **abstract unix socket `@tuple-daemon`**, sends
  its argv framed as `u64 len, u64 argc, "arg\0arg\0…"`, forwards stdin, and
  prints the plain text the daemon streams back until EOF.
- **Auto-start:** any command, even `tuple help`, spawns the daemon if none is
  listening. That's why the widget checks `/proc/net/unix` for
  `@tuple-daemon` and never runs a command while the daemon is off.
- **No status API:** there is no status or JSON command. Live state comes from
  the daemon log at `~/.local/share/tuple/<n>/log.txt`, which is truncated on
  every start and formatted `time|pid|tid|level|[File.cpp:N|]message`. The
  widget tails it and folds in these messages:
  - `signaler state changed: A -> B`
  - `received incoming call: X`
  - `peer joined call: X` and `peer left call: X`
  - `local user started/stopped sharing screen`
  - `peer started sharing screen: X`
  - `call ended` and friends
- **Command output:**
  - `tuple ls` prints `  ID Name <email> [available|unavailable|in call|offline]( (favorite))`.
  - `tuple call` prints the online favourites as `  N) Name <email>` and reads
    the chosen number from stdin. The panel answers that prompt for the person
    you clicked.
  - `tuple new` prints `personal url: https://tuple.app/c/…`.
  - `tuple settings` prints `name | value | description (a|b)`.
- **Call links:** `join` only accepts `https://tuple.app/c/…` or
  `https://production.tuple.app/c/…` links.
- **Tuple's own window:** `tuple ui` opens an X11 window that only shows a few
  lines of status text. It's the only place to accept an incoming call, so the
  Answer button opens it.

## Known gaps (alpha client)

- **Mute state:** mute is never logged. The widget tracks it from its own
  `mute`/`unmute` replies, the `start-calls-muted` setting, and the call
  starting. If you mute from a terminal, the widget won't know.
- **Untested call paths:** answering, and the exact log lines during real
  calls, haven't been tested yet. The parser is permissive, and
  `omarchy-shell sehl.tuple status` shows what it currently believes.
- **Calling restrictions:** you can only call online favourites, because
  that's all `tuple call` offers. Star someone to make them callable.

## Develop

```bash
node --test tests/*.test.mjs   # Model.js parsers + log reducer
omarchy plugin validate .
```

Files:

- `Model.js`: pure parsing and the state reducer; no QML.
- `Service.qml`: the daemon probe, log follower, and command runner.
- `Panel.qml`: the bar button and panel UI.
- `TupleIcon.qml`: the logo.
