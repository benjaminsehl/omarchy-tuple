import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// State + actions for the Tuple Linux client.
//
// Sources of truth (see Model.js header for the protocol notes):
//   1. /proc/net/unix          → is the daemon listening on @tuple-daemon?
//   2. tail -F <data>/log.txt  → signaler, peers, screen share, incoming calls
//   3. command replies         → everything we do ourselves (mute, share, …)
Item {
  id: root

  property var settings: ({})

  // ── Public state ──────────────────────────────────────────────────────
  property bool installed: true
  property bool daemon: false
  property bool daemonKnown: false
  property var log: Model.emptyState()
  property int auth: -1                    // -1 unknown, 0 logged out, 1 logged in
  property bool muted: false
  property var contacts: []
  property var contactCounts: ({ total: 0, favorites: 0, online: 0, onlineFavorites: 0 })
  property string _contactsText: ""
  property int _contactsSettle: 0
  property bool contactsLoaded: false
  property var tupleSettings: []
  property string personalUrl: ""
  property string loginUrl: ""
  property bool loginPending: false
  property string clipboardCallUrl: ""
  property string actionStatus: ""
  property string lastError: ""
  property var pending: ({})
  property bool socatAvailable: false
  // Non-empty while showing canned data (IPC `demo <scenario>`); live probes
  // and commands are suspended so nothing touches the real daemon.
  property string demo: ""

  readonly property bool loggedIn: daemon && auth === 1
  readonly property string call: daemon ? log.call : "idle"
  readonly property bool inCall: call === "active" || call === "connecting" || call === "ending"
  readonly property bool incoming: call === "incoming"
  readonly property bool sharing: inCall && log.sharing
  readonly property bool cameraOn: cameraProc.running
  readonly property var peers: daemon ? log.peers : []
  // The engine reports peers by contact id; show names where we know them.
  readonly property var peerNames: peers.map(function(p) { return root.peerName(p) })
  readonly property bool busy: Object.keys(pending).length > 0
  readonly property bool startCallsMuted: settingValue("start-calls-muted") === "1"
  readonly property string statusText: !installed ? "Tuple CLI not found" : Model.statusLabel({
    daemon: daemon, loggedIn: loggedIn, call: call, peers: peerNames,
    incomingFrom: log.incomingFrom, signaler: log.signaler
  })

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property bool notifyIncoming: setting("notifyIncoming", true) !== false
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")

  signal personalUrlCopied(string url)

  // ── Helpers ───────────────────────────────────────────────────────────
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function settingValue(name) {
    for (var i = 0; i < tupleSettings.length; i++) if (tupleSettings[i].name === name) return tupleSettings[i].value
    return ""
  }

  // Resolve `tuple` the same way an interactive shell would, plus the two
  // install locations offered on tuple.app/linux.
  function tupleArgv(args) {
    var bin = String(setting("tupleCommand", "tuple"))
    return ["bash", "-c", "PATH=\"$HOME/.local/bin:$HOME/bin:$PATH\"; exec " + Util.shellQuote(bin) + " \"$@\"", "tuple"].concat(args)
  }

  function isPending(name) { return pending[name] === true }

  function peerName(id) {
    var key = String(id)
    for (var i = 0; i < contacts.length; i++) if (contacts[i].id === key) return contacts[i].name
    return /^\d+$/.test(key) ? "Someone" : key
  }

  // Read-only queries go straight to the socket (see bin/tuple-request): the
  // stock CLI truncates big replies and would spawn the daemon if it's off.
  readonly property string requestHelper: String(Qt.resolvedUrl("bin/tuple-request")).replace(/^file:\/\//, "")
  readonly property var directCommands: ["ls", "settings"]

  function setPending(name, on) {
    var next = {}
    for (var k in pending) if (k !== name) next[k] = true
    if (on) next[name] = true
    pending = next
  }

  function say(text, isError) {
    actionStatus = isError ? "" : String(text || "")
    lastError = isError ? String(text || "") : ""
    statusClear.restart()
  }

  function copy(text, label) {
    var value = String(text || "")
    if (value === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s \"$1\" | wl-copy", "copy", value])
    say((label || "Copied") + " copied", false)
  }

  function openUrl(url) {
    if (String(url || "") !== "") Quickshell.execDetached(["xdg-open", String(url)])
  }

  function notify(summary, body, urgency) {
    Quickshell.execDetached(["notify-send", "-a", "Tuple", "-i", "tuple", "-u", urgency || "normal", summary, body || ""])
  }

  // ── Command runner ────────────────────────────────────────────────────
  // run(["mute"], { onLine, onDone, stdin }) — streams each output line to
  // onLine(line, proc) and calls onDone(reply) with Model.parseReply().
  function run(args, opts) {
    opts = opts || {}
    var name = String(args[0])
    if (demo !== "") { if (opts.quiet !== true) say("demo: tuple " + args.join(" "), false); return null }
    if (opts.exclusive !== false && isPending(name)) return null
    setPending(name, true)
    var proc = commandComponent.createObject(root, { args: args, opts: opts })
    proc.command = directCommands.indexOf(name) !== -1 && socatAvailable
      ? [requestHelper].concat(args)
      : tupleArgv(args)
    proc.running = true
    return proc
  }

  function finish(proc) {
    var args = proc.args
    var name = String(args[0])
    var text = proc.outLines.join("\n")
    var reply = Model.parseReply(text)
    setPending(name, false)
    if (name !== "ls" && name !== "settings") log = Model.reduceReply(log, name, reply)
    if (reply.lines.length < 5 && /not logged in/i.test(text)) auth = 0
    if (proc.opts.onDone) proc.opts.onDone(reply, proc)
    else if (proc.opts.quiet !== true && reply.message !== "") say(reply.message, !reply.ok)
    else if (!reply.ok) say(reply.message, true)
    Qt.callLater(function() { proc.destroy() })
  }

  Component {
    id: commandComponent

    Process {
      id: proc
      property var args: []
      property var opts: ({})
      // Lines are collected in an array: `tuple ls` on an org directory is
      // ~8k lines, and string += per line is quadratic.
      property var outLines: []
      // Interactive `tuple call`: answer once the numbered list stops growing.
      property var answer: null
      property Timer answerTimer: Timer {
        interval: 250
        onTriggered: if (proc.answer) proc.answer()
      }
      stdinEnabled: opts.stdin === true

      stdout: SplitParser {
        onRead: function(line) {
          proc.outLines.push(line)
          if (proc.opts.onLine) proc.opts.onLine(line, proc)
        }
      }
      stderr: SplitParser {
        onRead: function(line) { proc.outLines.push(line) }
      }
      onExited: root.finish(proc)
    }
  }

  // ── Daemon lifecycle ──────────────────────────────────────────────────
  function refresh() {
    probe.running = true
    if (daemon) {
      refreshContacts()
      refreshSettings()
    }
    readClipboard()
  }

  function turnOn() {
    run(["on"], { onDone: function(reply) { say(reply.ok ? "Tuple is on" : reply.message, !reply.ok); probe.running = true } })
  }

  // ── Demo data (for screenshots / UI work without an account) ───────────
  function setDemo(name) {
    var scenario = String(name || "")
    if (scenario === "" || scenario === "off") {
      demo = ""
      log = Model.emptyState()
      auth = -1
      muted = false
      personalUrl = ""
      daemonKnown = false
      follower.running = false
      probe.running = true
      return "live"
    }
    demo = scenario
    daemon = true
    daemonKnown = true
    auth = scenario === "login" ? 0 : 1
    loginUrl = scenario === "login" ? "https://production.tuple.app/start?code_challenge=demo&os=linux" : ""
    loginPending = scenario === "login"
    contacts = Model.parseContacts(
      "  101 Alice Smith <alice@example.com> [available] (favorite)\n"
      + "  102 Bob Jones <bob@example.com> [offline] (favorite)\n"
      + "  103 Carol Diaz <carol@example.com> [in call] (favorite)\n"
      + "  104 Dev Patel <dev@example.com> [available] (favorite)\n"
      + "  105 Erin Park <erin@example.com> [unavailable] (favorite)\n"
      + "  106 Femi Ade <femi@example.com> [offline]\n")
    contactsLoaded = true
    contactCounts = Model.contactCounts(contacts)
    tupleSettings = Model.parseSettings(
      "overlay | 1 | Show \"overlay\" annotation window when sharing screen (0|1)\n"
      + "start-calls-muted | 0 | Start with microphone muted when joining a call (0|1)\n"
      + "capture | auto | Screen capture mechanism (auto|x11|portal)\n")
    var s = Model.emptyState()
    s.version = "v2026_09_16.1"
    s.signaler = "connected"
    s.tokenSaved = scenario !== "login"
    if (scenario === "call") { s.call = "active"; s.peers = ["Alice Smith"]; s.sharing = true; muted = true; personalUrl = "https://tuple.app/c/demo-room" }
    if (scenario === "incoming") { s.call = "incoming"; s.incomingFrom = "Alice Smith" }
    log = s
    return scenario
  }

  function turnOff() {
    run(["off"], { onDone: function(reply) { say("Tuple stopped", false); probe.running = true } })
  }

  function toggleDaemon() { daemon ? turnOff() : turnOn() }

  function onDaemonUp() {
    refreshContacts()
    refreshSettings()
  }

  function onDaemonDown() {
    contacts = []
    contactsLoaded = false
    muted = false
    loginPending = false
  }

  // ── Account ───────────────────────────────────────────────────────────
  function login() {
    loginUrl = ""
    run(["login"], {
      onLine: function(line) {
        var url = Model.parseLoginUrl(line)
        if (url !== "") root.loginUrl = url
      },
      onDone: function(reply) {
        if (/already logged in/i.test(reply.message)) { root.auth = 1; root.loginPending = false; root.refreshContacts(); return }
        root.loginPending = reply.ok
        if (root.loginUrl === "") root.loginUrl = Model.parseLoginUrl(reply.lines.join("\n"))
        say(reply.ok ? "Finish logging in in your browser, then paste the code" : reply.message, !reply.ok)
      }
    })
  }

  function submitAuth(code) {
    var c = String(code || "").trim()
    if (c === "") return
    run(["auth", c], {
      onDone: function(reply) {
        var ok = reply.ok && !/login failed|unknown token/i.test(reply.lines.join("\n"))
        if (ok) {
          root.auth = 1
          root.loginPending = false
          root.loginUrl = ""
          say("Logged in", false)
          contactsRetry.restart()
        } else {
          say(reply.message || "Login failed", true)
        }
      }
    })
  }

  function logout() {
    run(["logout"], { onDone: function(reply) {
      root.auth = 0
      root.contacts = []
      root.contactsLoaded = false
      say(reply.ok ? "Logged out" : reply.message, !reply.ok)
    } })
  }

  // ── Contacts ──────────────────────────────────────────────────────────
  function refreshContacts() {
    if (!daemon) return
    run(["ls"], { quiet: true, onDone: function(reply, proc) {
      var text = proc.outLines.join("\n")
      if (reply.lines.length < 5 && /not logged in/i.test(text)) { root.auth = 0; root.contacts = []; root.contactsLoaded = false; root._contactsText = ""; return }
      if (!reply.ok && reply.lines.length < 5) { say(reply.message, true); return }
      root.auth = 1
      root.contactsLoaded = true
      if (text === root._contactsText) { root._contactsSettle = 0; return }
      // The daemon fills the directory in gradually after login/startup;
      // keep re-listing every few seconds until two reads agree.
      var grew = text.length > root._contactsText.length
      root._contactsText = text
      if (grew && root._contactsSettle < 12) { root._contactsSettle++; contactsRetry.interval = 5000; contactsRetry.restart() }
      var parsed = Model.parseContacts(text)
      root.contactCounts = Model.contactCounts(parsed)
      root.contacts = parsed
    } })
  }

  function toggleFavorite(contact) {
    if (!contact) return
    var verb = contact.favorite ? "unfavorite" : "favorite"
    run([verb, contact.id], { onDone: function(reply) {
      say(reply.ok ? (contact.favorite ? "Removed " : "Added ") + contact.name + (contact.favorite ? " from favorites" : " to favorites") : reply.message, !reply.ok)
      root.refreshContacts()
    } })
  }

  // `tuple call` only offers online favorites as a numbered prompt read from
  // stdin; answer it with the row that matches the chosen contact.
  function callContact(contact) {
    if (!contact) return
    var answered = false
    var choices = []
    var proc = run(["call"], {
      stdin: true,
      onLine: function(line, p) {
        var parsed = Model.parseCallChoices(line)
        if (parsed.length > 0) {
          choices = choices.concat(parsed)
          p.answerTimer.restart()
        } else if (answered) {
          root.actionStatus = line.trim()
        }
      },
      onDone: function(reply) {
        if (!answered) say(/no favorites online/i.test(reply.message) ? contact.name + " isn't online" : reply.message, true)
        else say(reply.message, !reply.ok)
      }
    })
    if (!proc) return
    proc.answer = function() {
      if (answered) return
      answered = true
      var choice = Model.choiceForContact(choices, contact)
      if (!choice) {
        proc.write("\n")
        proc.running = false
        say(contact.name + " must be an online favorite to call", true)
        return
      }
      proc.write(choice.index + "\n")
      say("Calling " + contact.name + "…", false)
    }
  }

  // ── Calls ─────────────────────────────────────────────────────────────
  function newCall() {
    run(["new"], {
      onLine: function(line) {
        var url = Model.parsePersonalUrl(line)
        if (url !== "") {
          root.personalUrl = url
          if (root.setting("copyLinkOnNewCall", true) !== false) {
            root.copy(url, "Call link")
            root.personalUrlCopied(url)
          }
        } else if (line.trim() !== "") {
          root.actionStatus = line.trim()
        }
      },
      onDone: function(reply) {
        if (!reply.ok) say(reply.message, true)
        else if (root.personalUrl !== "") say("Call link copied — share it to pair", false)
        else say(reply.message, false)
      }
    })
  }

  function join(url) {
    var u = Model.extractCallUrl(url) || String(url || "").trim()
    if (!Model.isCallUrl(u)) { say("That isn't a Tuple call link (https://tuple.app/c/…)", true); return }
    run(["join", u], { onLine: function(line) { if (line.trim() !== "") root.actionStatus = line.trim() } })
  }

  function setMuted(on) {
    run([on ? "mute" : "unmute"], { onDone: function(reply) {
      if (reply.ok || /^already/i.test(reply.message)) root.muted = on
      say(reply.ok ? (on ? "Microphone muted" : "Microphone live") : reply.message, !reply.ok)
    } })
  }

  function toggleMute() { setMuted(!muted) }

  function setSharing(on) {
    run([on ? "share" : "unshare"], { onDone: function(reply) {
      say(reply.ok ? (on ? "Sharing your screen" : "Stopped sharing") : reply.message, !reply.ok)
    } })
  }

  function toggleShare() { setSharing(!sharing) }

  function endCall() {
    run(["end"], { onDone: function(reply) { say(reply.ok ? "Call ended" : reply.message, !reply.ok) } })
  }

  // Tuple's own window owns answering; the CLI only exposes "end" to decline.
  function answer() { run(["ui"], { quiet: true }) }
  function decline() { endCall() }
  function openDebugUi() { run(["ui"], { quiet: true }) }

  // ── Camera ────────────────────────────────────────────────────────────
  // Tuple for Linux can't send webcam video yet (its WebcamCapturerAdapter is
  // a TODO in v2026_09_16.1). Until it can, show your camera as Omarchy's
  // floating WebcamOverlay — the same mpv window `omarchy capture
  // screenrecording --with-webcam` uses, so Omarchy's own window rules pin it
  // to the corner — and it reaches your peer through the screen share.
  function setCamera(on) {
    if (on === cameraProc.running) return
    if (on) {
      cameraProc.command = ["bash", "-c", cameraScript, "tuple-camera",
        String(setting("cameraDevice", "")), String(setting("cameraSize", "medium"))]
      cameraProc.stopping = false
      cameraProc.running = true
      say(sharing ? "Your camera is on your shared screen" : "Camera on — share your screen so they can see it", false)
    } else {
      cameraProc.stopping = true
      cameraProc.running = false
    }
  }

  function toggleCamera() { setCamera(!cameraProc.running) }

  readonly property string cameraScript:
    "dev=\"$1\"; size=\"${2:-medium}\"; "
    + "[ -n \"$dev\" ] || dev=$(omarchy-capture-webcam-list 2>/dev/null | sed -n '1s/[[:space:]].*//p'); "
    + "[ -n \"$dev\" ] || { echo 'No webcam found' >&2; exit 3; }; "
    + "opts=framerate=30; fmts=$(v4l2-ctl --list-formats-ext -d \"$dev\" 2>/dev/null); "
    + "for r in 640x360 1280x720 1920x1080; do case \"$fmts\" in *$r*) opts=\"video_size=$r,$opts\"; break;; esac; done; "
    + "exec mpv \"av://v4l2:$dev\" --profile=low-latency --untimed --no-cache "
    + "--demuxer-lavf-o=\"$opts\" '--vf=lavfi=[crop=ih*8/9:ih]' "
    + "--title=WebcamOverlay --wayland-app-id=\"WebcamOverlay-$size\" "
    + "--no-border --no-audio --no-osc --osd-level=0 --really-quiet"

  Process {
    id: cameraProc
    property bool stopping: false
    stderr: SplitParser { onRead: function(line) { if (line.trim() !== "") root.say(line.trim(), true) } }
    onExited: function(code) {
      if (!stopping && code !== 0) root.say(code === 3 ? "No webcam found" : "Camera stopped — is another app using it?", true)
      stopping = false
    }
  }

  // The overlay only makes sense during a call.
  onInCallChanged: if (!inCall && cameraProc.running && setting("cameraFollowsCall", true) !== false) setCamera(false)

  // ── Settings ──────────────────────────────────────────────────────────
  function refreshSettings() {
    if (!daemon) return
    run(["settings"], { quiet: true, onDone: function(reply) {
      if (reply.ok) root.tupleSettings = Model.parseSettings(reply.lines.join("\n"))
    } })
  }

  function setTupleSetting(name, value) {
    run(["set", name, String(value)], { exclusive: false, onDone: function(reply) {
      if (!reply.ok) say(reply.message, true)
      root.refreshSettings()
    } })
  }

  // ── Clipboard ─────────────────────────────────────────────────────────
  function readClipboard() { if (!clipboardProc.running) clipboardProc.running = true }

  Process {
    id: clipboardProc
    command: ["bash", "-c", "wl-paste -n -t text 2>/dev/null | head -c 4096"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.clipboardCallUrl = Model.extractCallUrl(text)
    }
  }

  // ── Probes and followers ──────────────────────────────────────────────
  Process {
    id: whichProc
    running: true
    command: ["bash", "-c", "PATH=\"$HOME/.local/bin:$HOME/bin:$PATH\"; command -v " + Util.shellQuote(String(root.setting("tupleCommand", "tuple"))) + " >/dev/null"]
    onExited: function(code) { root.installed = code === 0 }
  }

  Process {
    running: true
    command: ["bash", "-c", "command -v socat >/dev/null"]
    onExited: function(code) { root.socatAvailable = code === 0 }
  }

  Process {
    id: probe
    command: ["grep", "-qs", "@tuple-daemon", "/proc/net/unix"]
    onExited: function(code) {
      if (root.demo !== "") return
      var up = code === 0
      var changed = up !== root.daemon || !root.daemonKnown
      root.daemon = up
      root.daemonKnown = true
      if (changed) up ? root.onDaemonUp() : root.onDaemonDown()
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!probe.running) probe.running = true
  }

  // The log is truncated each time the daemon starts; tail -F follows that
  // and re-reads from the top, and Model.reduceLog resets on the banner.
  Process {
    id: follower
    running: true
    command: ["bash", "-c",
      "d=\"$1/tuple\"; pick() { ls -t \"$d\"/*/log.txt 2>/dev/null | head -1; }; "
      + "f=$(pick); while [ -z \"$f\" ]; do sleep 3; f=$(pick); done; "
      + "exec tail -n +1 -F \"$f\" 2>/dev/null", "follow", root.dataHome]
    stdout: SplitParser {
      onRead: function(line) {
        var entry = Model.parseLogLine(line)
        if (!entry || root.demo !== "") return
        var before = root.log
        var next = Model.reduceLog(before, entry)
        if (next === before) return
        root.log = next
        root.onLogEvent(before, next, entry)
      }
    }
    onExited: followerRestart.restart()
  }

  Timer { id: followerRestart; interval: 3000; onTriggered: follower.running = true }

  // Log times are UTC; replays on shell start shouldn't trigger side effects.
  function isLive(entry) {
    var d = new Date()
    var now = d.getUTCHours() * 3600 + d.getUTCMinutes() * 60 + d.getUTCSeconds()
    var diff = Math.abs(now - Model.logSeconds(entry.time))
    return Math.min(diff, 86400 - diff) < 30
  }

  function onLogEvent(before, next, entry) {
    if (next.call === "ending") endingFallback.restart()
    if (next.peerWebcam && !before.peerWebcam && isLive(entry) && setting("webcamPip", true) !== false && !pipProc.running) pipProc.running = true
    if (next.tokenSaved && !before.tokenSaved) auth = 1
    if (Model.isSignalerOnline(next.signaler) && !Model.isSignalerOnline(before.signaler)) {
      if (auth !== 1) { auth = 1; refreshContacts() }
    }
    if (next.exited && !before.exited) probe.running = true
    if (before.call === "idle" && next.call !== "idle" && next.call !== "incoming") muted = startCallsMuted
    if (next.call === "idle" && before.call !== "idle") muted = false
    if (next.call === "incoming" && before.call !== "incoming" && notifyIncoming) {
      notify("Incoming Tuple call", (next.incomingFrom || "Someone") + " wants to pair", "critical")
    }
  }

  Process {
    id: pipProc
    command: [String(Qt.resolvedUrl("bin/tuple-pip")).replace(/^file:\/\//, ""), "8"]
  }

  // An `end` issued elsewhere shows up only as `cli: end`; if the daemon goes
  // quiet afterwards there's no later log line to resolve "ending" with.
  Timer {
    id: endingFallback
    interval: 4000
    onTriggered: if (root.log.call === "ending") root.log = Model.resolveEnding(root.log)
  }

  // The daemon truncates its log on every start, which is the only record of
  // what a real call looked like. Keep a rolling copy per daemon run.
  Timer {
    interval: 15000
    running: root.daemon && root.setting("archiveLogs", true) !== false
    repeat: true
    onTriggered: if (!archiver.running) archiver.running = true
  }

  Process {
    id: archiver
    command: ["bash", "-c",
      "src=$(ls -t \"$1\"/tuple/*/log.txt 2>/dev/null | head -1); [ -n \"$src\" ] || exit 0; "
      + "dst=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-tuple/logs\"; mkdir -p \"$dst\"; "
      + "pid=$(head -c 200 \"$src\" | head -1 | cut -d'|' -f2); [ -n \"$pid\" ] || exit 0; "
      + "out=\"$dst/$(date -r \"$src\" +%F)-$pid.log\"; cmp -s \"$src\" \"$out\" || cp \"$src\" \"$out\"; "
      + "ls -t \"$dst\"/*.log | tail -n +21 | xargs -r rm --", "archive", root.dataHome]
  }

  Timer { id: statusClear; interval: 6000; onTriggered: { root.actionStatus = ""; root.lastError = "" } }
  Timer { id: contactsRetry; interval: 1500; onTriggered: root.refreshContacts() }

  // Presence changes aren't in the log, so re-list contacts periodically.
  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.loggedIn
    repeat: true
    onTriggered: root.refreshContacts()
  }
}
