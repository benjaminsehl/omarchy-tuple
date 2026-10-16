# Tuple for Omarchy

A native [Omarchy](https://omarchy.org) bar widget and panel for
[Tuple's Linux client](https://tuple.app/linux/) (alpha, v2026_09_16.1). Tuple
for Linux is a command-line tool; this gives it a home in your bar. It's built
with the same Quickshell UI kit as Omarchy's own Tailscale, Bluetooth and Audio
panels, so it picks up your theme, fonts, borders and keyboard conventions.

<table>
  <tr>
    <td><img src="docs/screenshots/idle.png" width="385" alt="Ready to pair: one field to start or join a call, then available teammates"></td>
    <td><img src="docs/screenshots/call.png" width="385" alt="In a call: mute, share, camera, copy link and end"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Ready to pair.</b> One field starts or joins a call. Teammates are listed available-first, with presence shown once.</sub></td>
    <td align="center"><sub><b>In a call.</b> The controls show state (Muted, Sharing), and the bar icon turns the active colour.</sub></td>
  </tr>
  <tr>
    <td><img src="docs/screenshots/incoming.png" width="385" alt="Incoming call with Answer and Decline"></td>
    <td><img src="docs/screenshots/login.png" width="385" alt="Browser login with an authorization code field"></td>
  </tr>
  <tr>
    <td align="center"><sub><b>Incoming call.</b> The bar icon pulses and you get a desktop notification.</sub></td>
    <td align="center"><sub><b>Log in.</b> Login continues in your browser; paste the code back here.</sub></td>
  </tr>
</table>

<sub>Screenshots use the built-in demo data (`omarchy-shell sehl.tuple demo <state>`) on a dark Omarchy theme.</sub>

## What you get

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
  bottom-right corner. The static rule covers the `tuple-webcams` Wayland app
  ID. In practice Tuple opens the webcam window over X11, where it's just
  class `Tuple`, so `bin/tuple-pip` does the same thing at runtime when the
  daemon logs `webcam: added feed`. It stays on every workspace, never steals focus, and
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

## Requirements

- Omarchy with the Quickshell-based shell (`omarchy-shell`)
- The Tuple CLI from [tuple.app/linux](https://tuple.app/linux/) on your
  `PATH`; `~/.local/bin` and `~/bin` are checked too
- `socat`, `jq`, `hyprctl`, `wl-copy` and `notify-send`
- For the camera overlay: `mpv` and `v4l2-ctl`. Omarchy ships these.

## Install

```bash
git clone https://github.com/benjaminsehl/omarchy-tuple.git ~/Code/omarchy-tuple
cd ~/Code/omarchy-tuple
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
- **Truncated replies:** the daemon writes replies with non-blocking sends and
  drops the rest on `EAGAIN` (`write to deferred ls pipe failed, error=11`).
  The stock CLI drains too slowly, so `tuple ls` returns only ~71 of ~7,800
  people. `bin/tuple-request` speaks the socket protocol through `socat` and
  gets everything; the widget uses it for `ls` and `settings`.
- **No status API:** there is no status or JSON command. Live state comes from
  the daemon log at `~/.local/share/tuple/<n>/log.txt`, which is truncated on
  every start and formatted `time|pid|tid|level|[File.cpp:N|]message`. The
  widget tails it and folds in these messages:
  - `signaler state changed: A -> B`
  - `received incoming call: X`
  - `peer joined call: X` and `peer left call: X`
  - `call connected`
  - `EngineEvent: OnPeerAdded/OnPeerRemoved (peer <contact id> …)`, mapped to
    names from `ls`
  - `OnVideoCapturerDesktop Start/Stop` (your screen share)
  - `webcam: added feed` and `WebcamReceivingChange` (their webcam)
  - `cli: end`, then `call ended`, a remote hang-up, or the call's audio
    context (`ContextState: TERMINATED`)
  - **Log replays:** on a shell restart the log is replayed without the
    commands' replies, so `cli: end` resolves to idle once the log moves 3s
    past it.
- **Log archive:** the log is truncated whenever the daemon restarts. The
  widget keeps a rolling copy of the last 20 runs in
  `~/.local/state/omarchy-tuple/logs/`, which is what the parser is
  calibrated against.
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
- **Partly verified:** call state is calibrated against one real call (peers,
  screen share, their webcam, ending). Answering an incoming call and the
  runtime webcam PiP haven't been seen live yet. `omarchy-shell sehl.tuple
  status` shows what the widget currently believes.
- **Calling restrictions:** you can only call online favourites, because
  that's all `tuple call` offers. Star someone to make them callable.

## Develop

```bash
node --test tests/*.test.mjs   # Model.js parsers + log reducer
omarchy plugin validate .
```

Files:

- `Model.js`: pure parsing and the state reducer; no QML.
- `Service.qml`: the daemon probe, log follower, command runner and camera
  overlay.
- `Panel.qml`: the bar button and panel UI.
- `TupleIcon.qml`: the logo.
- `bin/tuple-request`: talks to the daemon socket directly, for complete
  replies and without starting the daemon.
- `bin/tuple-pip`: floats Tuple's X11 webcam window as a picture-in-picture.
- `hypr/tuple.lua`: Hyprland window rules.
- `docs/screenshots/`: screenshots for this README, captured with `demo` mode.

The panel follows a few design rules:

- The status line under the title says where you are, so sections don't
  repeat it.
- One control per intent.
- Presence is shown once.
- Secondary actions appear on the row you point at.
- Shortcuts live in tooltips, not on the controls.
