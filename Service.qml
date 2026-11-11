import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// State + actions for the Tuple Linux client.
//
// Sources of truth (see Model.js header for the protocol notes):
//   1. /proc/net/unix          → is the daemon listening on its socket?
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
  property bool startingCall: false        // "New call" is joining your personal room
  property string loginUrl: ""
  property bool loginPending: false
  property string clipboardCallUrl: ""
  property string actionStatus: ""
  property string lastError: ""
  property var pending: ({})
  // Non-empty while showing canned data (IPC `demo <scenario>`); live probes
  // and commands are suspended so nothing touches the real daemon.
  property string demo: ""

  readonly property bool loggedIn: daemon && auth === 1
  readonly property string call: daemon ? log.call : "idle"
  readonly property bool inCall: call === "active" || call === "connecting" || call === "ending"
  readonly property bool incoming: call === "incoming"
  readonly property bool sharing: inCall && log.sharing
  readonly property bool cameraOn: cameraProc.running
  property var cameras: []                 // [{ dev, name }] from omarchy-capture-webcam-list
  // Your chosen camera, or the first one when it isn't plugged in.
  readonly property var camera: Model.resolveCamera(cameras, setting("cameraDevice", ""))
  readonly property bool cameraIsDefault: String(setting("cameraDevice", "")) === "" || !Model.findCamera(cameras, setting("cameraDevice", ""))
  // Microphones (PulseAudio/PipeWire sources). Blank `micDevice` follows the
  // system default; otherwise Tuple's recording stream is moved to it.
  property var mics: []                    // [{ name, label }]
  property string defaultMic: ""           // source name of the system default
  readonly property string micDevice: String(setting("micDevice", ""))
  readonly property var mic: Model.findMic(mics, micDevice !== "" ? micDevice : defaultMic)
  readonly property bool micIsDefault: micDevice === "" || !Model.findMic(mics, micDevice)
  readonly property var peers: daemon ? log.peers : []
  // The engine reports peers by contact id; show names where we know them.
  readonly property var peerNames: peers.map(function(p) { return root.peerName(p) })
  readonly property bool busy: Object.keys(pending).length > 0
  readonly property bool startCallsMuted: settingValue("start-calls-muted") === "1"
  readonly property string statusText: !installed ? "Tuple CLI not found" : Model.statusLabel({
    daemon: daemon, loggedIn: loggedIn, call: call, peers: peerNames, outgoing: log.outgoing,
    incomingFrom: log.incomingFrom, signaler: log.signaler
  })

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 10, 3600)
  readonly property bool notifyIncoming: setting("notifyIncoming", true) !== false
  readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")

  signal personalUrlCopied(string url)
  // Ask the host to persist plugin settings (Panel owns bar.shell).
  signal settingsChangeRequested(var values)

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

  // "call mute", "contacts list", "start": grouped commands are named by both words.
  function commandName(args) {
    var group = ["call", "contacts", "rooms"]
    return group.indexOf(String(args[0])) !== -1 ? args[0] + " " + args[1] : String(args[0])
  }

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

  // A notification with one button; clicking it runs `command` (argv).
  // notify-send -A blocks until the notification closes, so it runs detached.
  function notifyAction(summary, body, urgency, label, command) {
    Quickshell.execDetached(["bash", "-c",
      "a=$(notify-send -a Tuple -i tuple -u \"$1\" -A go=\"$2\" \"$3\" \"$4\"); shift 4; [ \"$a\" = go ] && exec \"$@\"",
      "notify", urgency || "normal", label, summary, body || ""].concat(command))
  }

  function focusWindowCommand(title) {
    return ["hyprctl", "dispatch", "hl.dsp.focus({ window = \"title:^" + title + "$\" })"]
  }

  // ── Command runner ────────────────────────────────────────────────────
  // run(["mute"], { onLine, onDone, stdin }) — streams each output line to
  // onLine(line, proc) and calls onDone(reply) with Model.parseReply().
  function run(args, opts) {
    opts = opts || {}
    var name = commandName(args)
    if (demo !== "") { if (opts.quiet !== true) say("demo: tuple " + args.join(" "), false); return null }
    if (opts.exclusive !== false && isPending(name)) return null
    setPending(name, true)
    var proc = commandComponent.createObject(root, { args: args, opts: opts })
    proc.command = tupleArgv(args)
    proc.running = true
    return proc
  }

  // Seconds each command may take before we give up on it. `call start` waits
  // on the ring; `login` on the browser; everything else answers at once.
  function commandTimeout(name, opts) {
    if (opts && opts.timeoutMs) return opts.timeoutMs
    if (name === "call start") return 120000
    if (name === "login" || name === "auth") return 90000
    if (name === "contacts list" || name === "settings" || name === "start" || name === "stop") return 45000
    return 20000
  }

  function finish(proc, code) {
    var name = commandName(proc.args)
    if (proc.timedOut && proc.outLines.length === 0) proc.outLines.push("error: Tuple didn't respond to “" + name + "”")
    var text = proc.outLines.join("\n")
    var reply = Model.parseReply(text)
    if (code !== 0) reply.ok = false
    setPending(name, false)
    if (name !== "contacts list" && name !== "rooms list" && name !== "settings") log = Model.reduceReply(log, name, reply)
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
      // Collected in an array: string += per line is quadratic on long replies.
      property var outLines: []
      property int exitStatus: 0
      // A wedged daemon or socket must not leave a button "busy" forever.
      property bool timedOut: false
      property Timer watchdog: Timer {
        running: proc.running
        interval: root.commandTimeout(root.commandName(proc.args), proc.opts)
        onTriggered: { proc.timedOut = true; proc.running = false }
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
      onExited: function(code) { proc.exitStatus = code; root.finish(proc, code) }
    }
  }

  // ── Daemon lifecycle ──────────────────────────────────────────────────
  // Opening the panel refreshes everything, but not more than every 15s:
  // the device lists spawn v4l2-ctl and
  // pactl. The periodic timer and explicit actions still refresh as needed.
  property double lastRefreshAt: 0
  function refresh(force) {
    probe.running = true
    readClipboard()
    var now = Date.now()
    if (force !== true && now - lastRefreshAt < 15000) return
    lastRefreshAt = now
    if (daemon) {
      refreshContacts()
      refreshSettings()
    }
    refreshCameras()
    refreshMics()
  }

  function turnOn() {
    run(["start"], { onDone: function(reply) { say(reply.ok ? "Tuple is on" : reply.message, !reply.ok); probe.running = true } })
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
    contacts = Model.parseContacts(JSON.stringify([
      { id: 101, full_name: "Alice Smith", email: "alice@example.com", status: "online", favorited: true },
      { id: 102, full_name: "Bob Jones", email: "bob@example.com", status: "offline", favorited: true },
      { id: 103, full_name: "Carol Diaz", email: "carol@example.com", status: "busy", favorited: true },
      { id: 104, full_name: "Dev Patel", email: "dev@example.com", status: "online", favorited: true },
      { id: 105, full_name: "Erin Park", email: "erin@example.com", status: "unknown", favorited: true },
      { id: 106, full_name: "Femi Ade", email: "femi@example.com", status: "offline", favorited: false }
    ]))
    contactsLoaded = true
    contactCounts = Model.contactCounts(contacts)
    tupleSettings = Model.parseSettings(
      "overlay | 1 | Show \"overlay\" annotation window when sharing screen (0|1)\n"
      + "start-calls-muted | 0 | Start with microphone muted when joining a call (0|1)\n"
      + "capture | auto | Screen capture mechanism (auto|x11|portal)\n")
    var s = Model.emptyState()
    s.version = "v2026_11_02.0"
    s.signaler = "connected"
    s.tokenSaved = scenario !== "login"
    if (scenario === "call") { s.call = "active"; s.peers = ["Alice Smith"]; s.sharing = true; muted = true; personalUrl = "https://tuple.app/c/demo-room" }
    if (scenario === "viewing") { s.call = "active"; s.peers = ["Alice Smith"]; s.peerWebcam = true; s.peerSharing = "Alice Smith"; s.windows = ["webcam", "screen"]; personalUrl = "https://tuple.app/c/demo-room" }
    if (scenario === "incoming") { s.call = "incoming"; s.incomingFrom = "Alice Smith" }
    log = s
    return scenario
  }

  function turnOff() {
    run(["stop"], { onDone: function(reply) { say("Tuple stopped", false); probe.running = true } })
  }

  function toggleDaemon() { daemon ? turnOff() : turnOn() }

  function onDaemonUp() {
    refreshContacts()
    refreshPersonalUrl()
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
    run(["contacts", "list", "--format", "json"], { quiet: true, onDone: function(reply, proc) {
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
    run(["contacts", verb, contact.email], { onDone: function(reply) {
      say(reply.ok ? (contact.favorite ? "Removed " : "Added ") + contact.name + (contact.favorite ? " from favorites" : " to favorites") : reply.message, !reply.ok)
      root.refreshContacts()
    } })
  }

  // `call start` rings them and exits 0 once they answer, 2 if the call ends first.
  function callContact(contact) {
    if (!contact) return
    var proc = run(["call", "start", contact.email], {
      onDone: function(reply, p) {
        root.log = Model.finishOutgoing(root.log, p.exitStatus === 0)
        if (p.exitStatus === 2) say(contact.name + " didn't answer", true)
        else say(reply.ok ? "Pairing with " + contact.name : reply.message, !reply.ok)
      }
    })
    if (!proc) return
    log = Model.startOutgoing(log)
    say("Calling " + contact.name + "…", false)
  }

  // ── Calls ─────────────────────────────────────────────────────────────
  // A new call is your personal room; its URL comes from `rooms list`.
  function refreshPersonalUrl(then) {
    run(["rooms", "list", "--format", "json"], { quiet: true, onDone: function(reply, proc) {
      var url = reply.ok ? Model.parsePersonalUrl(proc.outLines.join("\n")) : ""
      if (url !== "") root.personalUrl = url
      if (then) then(url, reply)
    } })
  }

  function newCall() {
    if (personalUrl === "") {
      refreshPersonalUrl(function(url, reply) {
        if (url !== "") root.newCall()
        else say(reply.ok ? "Tuple has no personal room for you" : reply.message, true)
      })
      return
    }
    if (setting("copyLinkOnNewCall", true) !== false) {
      copy(personalUrl, "Call link")
      personalUrlCopied(personalUrl)
    }
    startingCall = true
    run(["call", "join", personalUrl], { onDone: function(reply) {
      root.startingCall = false
      say(reply.ok ? "Call link copied — share it to pair" : reply.message, !reply.ok)
    } })
  }

  function join(url) {
    var u = Model.extractCallUrl(url) || String(url || "").trim()
    if (!Model.isCallUrl(u)) { say("That isn't a Tuple call link (https://tuple.app/c/…)", true); return }
    run(["call", "join", u], { onLine: function(line) { if (line.trim() !== "") root.actionStatus = line.trim() } })
  }

  function setMuted(on) {
    run(["call", on ? "mute" : "unmute"], { onDone: function(reply) {
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
    run(["call", "leave"], { onDone: function(reply) { say(reply.ok ? "Call ended" : reply.message, !reply.ok) } })
  }

  function answer() {
    run(["call", "accept"], { onDone: function(reply) { say(reply.ok ? "Call accepted" : reply.message, !reply.ok) } })
  }

  // Their shared screen is Tuple's "screen" window (named by tuple-windows).
  function viewScreen() {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.focus({ window = \"title:^tuple-screen$\" })"])
  }

  // How you interact with their screen: draw on it, or drive it.
  readonly property string guestMode: settingValue("guest-mode") || "annotation"
  function setGuestMode(mode) {
    if (mode !== "annotation" && mode !== "control") return
    setTupleSetting("guest-mode", mode)
    say(mode === "control" ? "You can control their screen" : "You can draw on their screen", false)
  }
  function decline() { endCall() }
  function openDebugUi() { run(["ui"], { quiet: true }) }

  // ── Camera ────────────────────────────────────────────────────────────
  // Tuple for Linux can't send webcam video yet: its WebcamCapturerAdapter is
  // a TODO in v2026_09_16.1 and it rejects ShareWebcamRequest. Until it can,
  // your camera is a local tile (bin/tuple-selfcam) on the call stage next to
  // theirs, and it reaches them only through your screen share.
  function setCamera(on) {
    if (on === cameraProc.running) return
    if (on) {
      startCamera(camera ? camera.dev : String(setting("cameraDevice", "")))
      say(sharing ? "They see your camera through your screen share" : "Only you can see this until you share your screen", !sharing)
    } else {
      cameraProc.stopping = true
      cameraProc.running = false
    }
  }

  function startCamera(dev) {
    cameraProc.command = [helper("tuple-selfcam"), String(dev || "")]
    cameraProc.stopping = false
    cameraProc.running = true
    arrangeWindows()
  }

  readonly property string stageSize: String(setting("cameraSize", "medium"))
  onStageSizeChanged: arrangeWindows()

  function helper(name) { return String(Qt.resolvedUrl("bin/" + name)).replace(/^file:\/\//, "") }

  // ── Window placement (bin/tuple-windows) ──────────────────────────────
  // Names Tuple's X11 windows by role, centres its prompts and lays out the
  // camera stage. Re-run whenever a Tuple window or your camera comes or goes.
  function arrangeWindows() {
    if (demo !== "") return
    if (windowsProc.running) { windowsProc.again = true; return }
    windowsProc.command = [helper("tuple-windows"), String(setting("cameraSize", "medium"))]
    windowsProc.running = true
  }

  // After a shell restart mid-call the log replay doesn't place anything
  // (side effects only fire for live lines); tidy up once it has settled.
  Timer {
    interval: 5000
    running: true
    onTriggered: if (root.log.windows.length > 0 || root.cameraOn) root.arrangeWindows()
  }

  Process {
    id: windowsProc
    property bool again: false
    onExited: if (again) { again = false; root.arrangeWindows() }
  }

  // Evidence for "the video was choppy": a CPU/window-size sample every 20s
  // of a call, in ~/.local/state/omarchy-tuple/perf.log (bin/tuple-perf).
  Timer {
    interval: 20000
    repeat: true
    running: root.inCall && root.demo === "" && root.setting("perfLog", true) !== false
    onTriggered: if (!perfProc.running) perfProc.running = true
  }
  Process { id: perfProc; command: [root.helper("tuple-perf")] }

  function toggleCamera() { setCamera(!cameraProc.running) }

  // Remember the camera by name (/dev/videoN numbers move between boots) and,
  // if the overlay is up, switch it over straight away.
  function chooseCamera(cam) {
    if (!cam) return
    settingsChangeRequested({ cameraDevice: cam.name })
    if (cameraProc.running) {
      cameraProc.switchTo = cam.dev        // reopened in onExited, once mpv lets go
      cameraProc.stopping = true
      cameraProc.running = false
    }
    say("Camera: " + cam.name, false)
  }

  function cycleCamera() { chooseCamera(Model.nextCamera(cameras, camera)) }

  // "" = system default.
  function chooseCameraName(name) {
    var n = String(name || "")
    if (n === "") {
      settingsChangeRequested({ cameraDevice: "" })
      var first = cameras.length > 0 ? cameras[0] : null
      if (cameraProc.running && first) { cameraProc.switchTo = first.dev; cameraProc.stopping = true; cameraProc.running = false }
      say("Camera: system default", false)
      return
    }
    chooseCamera(Model.findCamera(cameras, n))
  }

  // ── Microphone ────────────────────────────────────────────────────────
  function refreshMics() { if (!micList.running) micList.running = true }

  Process {
    id: micList
    command: ["bash", "-c", "pactl get-default-source 2>/dev/null; echo '---'; pactl -f json list sources 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: {
        var at = text.indexOf("---")
        if (at < 0) return
        root.defaultMic = text.slice(0, at).trim()
        root.mics = Model.parseMics(text.slice(at + 3))
      }
    }
  }

  // "" = system default.
  function chooseMic(name) {
    var n = String(name || "")
    settingsChangeRequested({ micDevice: n })
    var m = Model.findMic(mics, n)
    say(n === "" ? "Microphone: system default" : "Microphone: " + (m ? m.label : n), false)
  }

  function selectMic(query) {
    var q = String(query || "").trim()
    if (q === "" || q === "default") { chooseMic(""); return }
    var n = parseInt(q, 10)
    if (/^\d+$/.test(q) && n >= 1 && n <= mics.length) { chooseMic(mics[n - 1].name); return }
    var lower = q.toLowerCase()
    for (var i = 0; i < mics.length; i++) {
      if (mics[i].name === q || mics[i].label.toLowerCase().indexOf(lower) !== -1) { chooseMic(mics[i].name); return }
    }
    say("No microphone matches “" + q + "”", true)
  }

  // While a call is up, keep Tuple's mic stream on the chosen input. With
  // "system default" it's left alone, unless you switch back mid-call.
  readonly property string micRouteTarget: micDevice !== "" ? micDevice : (micRoutedThisCall ? "@DEFAULT_SOURCE@" : "")
  property bool micRoutedThisCall: false
  readonly property string micRouteKey: (inCall && micRouteTarget !== "") ? (log.pid + "|" + micRouteTarget) : ""
  onMicRouteKeyChanged: {
    micRoute.running = false
    if (micRouteKey === "") return
    if (micDevice !== "") micRoutedThisCall = true
    micRoute.command = [String(Qt.resolvedUrl("bin/tuple-mic-route")).replace(/^file:\/\//, ""), String(log.pid), micRouteTarget]
    Qt.callLater(function() { if (root.micRouteKey !== "") micRoute.running = true })
  }

  Process { id: micRoute }

  // Pick a camera by name, device path, or 1-based position (IPC).
  function selectCamera(query) {
    var q = String(query || "").trim()
    if (q === "" || q === "default") { chooseCameraName(""); return }
    var n = parseInt(q, 10)
    if (/^\d+$/.test(q) && n >= 1 && n <= cameras.length) { chooseCamera(cameras[n - 1]); return }
    var lower = q.toLowerCase()
    for (var i = 0; i < cameras.length; i++) {
      if (cameras[i].dev === q || cameras[i].name.toLowerCase().indexOf(lower) !== -1) { chooseCamera(cameras[i]); return }
    }
    say("No camera matches “" + q + "”", true)
  }

  function refreshCameras() { if (!cameraList.running) cameraList.running = true }
  Component.onCompleted: { refreshCameras(); refreshMics() }

  Process {
    id: cameraList
    command: ["bash", "-c", "omarchy-capture-webcam-list 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: root.cameras = Model.parseCameras(text)
    }
  }

  Process {
    id: cameraProc
    property bool stopping: false
    property string switchTo: ""
    stderr: SplitParser { onRead: function(line) { if (line.trim() !== "") root.say(line.trim(), true) } }
    onExited: function(code) {
      if (!stopping && code !== 0) root.say(code === 3 ? "No webcam found" : "Camera stopped — is another app using it?", true)
      stopping = false
      root.arrangeWindows()
      if (switchTo !== "") { var dev = switchTo; switchTo = ""; Qt.callLater(function() { root.startCamera(dev) }) }
    }
  }

  // The overlay only makes sense during a call.
  onInCallChanged: {
    if (!inCall) micRoutedThisCall = false
    if (!inCall && cameraProc.running && setting("cameraFollowsCall", true) !== false) setCamera(false)
    if (inCall) { refreshMics(); refreshCameras() }
  }

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
    id: probe
    command: ["grep", "-qsE", "@tuple-daemon|/tuple-0$", "/proc/net/unix"]
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
      // While they share, Tuple logs every move of their cursor (~99% of a
      // call's log). Drop that before it reaches QML. tail --pid ties tail's
      // life to this process (grep, after exec), so stopping the follower
      // doesn't leave tail running on a quiet log.
      + "exec grep --line-buffered -vE '\\|user [0-9]+ mouse |TODO: handle cursor update' "
      + "< <(exec tail --pid=$$ -n +1 -F \"$f\" 2>/dev/null)", "follow", root.dataHome]
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

  // Mute and call end, from the daemon's own state stream (v2026_11 and later).
  Process {
    id: stateFollower
    running: root.daemon && root.demo === ""
    command: root.tupleArgv(["state", "follow", "--format", "json"])
    stdout: SplitParser {
      onRead: function(line) {
        var summary = Model.parseJson(line, null)
        if (!summary || summary.in_call === undefined) return
        if (summary.call) root.muted = summary.call.muted === true
        root.log = Model.applySummary(root.log, summary)
      }
    }
    onExited: if (root.daemon) stateFollowerRestart.restart()
  }

  Timer { id: stateFollowerRestart; interval: 3000; onTriggered: stateFollower.running = root.daemon && root.demo === "" }

  // Log times are UTC; replays on shell start shouldn't trigger side effects.
  function isLive(entry) {
    var d = new Date()
    var now = d.getUTCHours() * 3600 + d.getUTCMinutes() * 60 + d.getUTCSeconds()
    var diff = Math.abs(now - Model.logSeconds(entry.time))
    return Math.min(diff, 86400 - diff) < 30
  }

  function onLogEvent(before, next, entry) {
    if (next.call === "ending") endingFallback.restart()
    if (next.outgoing && !before.outgoing) outgoingFallback.restart()
    if (next.unanswered !== "" && next.unanswered !== before.unanswered && isLive(entry)) {
      var who = peerName(next.unanswered)
      say((who === "Someone" ? "No one" : who) + " didn't answer", true)
      notify("No answer", (who === "Someone" ? "They" : who) + " didn't pick up. Try New call and send them the link.", "normal")
    }
    if (next.windows.join() !== before.windows.join() && isLive(entry)) arrangeWindows()
    if (next.joinRequest && !before.joinRequest && isLive(entry)) {
      notifyAction("Someone wants to join", "Let them in from Tuple's prompt.", "critical", "Show", focusWindowCommand("tuple-join-request"))
    }
    if (next.joined !== "" && next.joined !== before.joined && isLive(entry) && setting("notifyJoins", true) !== false) {
      var joinedId = next.joined.split("@")[0]
      Quickshell.execDetached(["notify-send", "-a", "Tuple", "-i", "tuple", "-t", "4000", "-h", "boolean:transient:true",
        (joinedId !== "" ? peerName(joinedId) : "Someone") + " joined", "You're pairing now."])
    }
    if (next.everyoneLeft && !before.everyoneLeft && isLive(entry)) {
      notifyAction("Everyone left", "Your call is still open. End it?", "normal", "End call", tupleArgv(["call", "leave"]))
    }
    if (next.tokenSaved && !before.tokenSaved) auth = 1
    if (Model.isSignalerOnline(next.signaler) && !Model.isSignalerOnline(before.signaler)) {
      if (auth !== 1) { auth = 1; refreshContacts() }
    }
    if (next.exited && !before.exited) probe.running = true
    if (before.call === "idle" && next.call !== "idle" && next.call !== "incoming") muted = startCallsMuted
    if (next.call === "idle" && before.call !== "idle") muted = false
    if (next.call === "incoming" && before.call !== "incoming" && notifyIncoming && isLive(entry)) incomingNotice.restart()
  }

  // The caller is only logged as a peer just after the call itself; wait for
  // them so the notification can say who it is.
  Timer {
    id: incomingNotice
    interval: 500
    onTriggered: {
      if (root.log.call !== "incoming") return
      var who = root.log.incomingFrom || (root.log.peers.length > 0 ? peerName(root.log.peers[0]) : "Someone")
      notifyAction("Incoming Tuple call", who + " wants to pair", "critical", "Show", focusWindowCommand("tuple-incoming-call"))
    }
  }

  // An `end` issued elsewhere shows up only as `cli: end`; if the daemon goes
  // quiet afterwards there's no later log line to resolve "ending" with.
  Timer {
    id: endingFallback
    interval: 4000
    onTriggered: if (root.log.call === "ending") root.log = Model.resolveEnding(root.log)
  }

  // `cli: call` with nobody dialled (prompt abandoned) never logs an outcome.
  Timer {
    id: outgoingFallback
    interval: 40000
    onTriggered: root.log = Model.resolveStaleOutgoing(root.log)
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
    command: [root.helper("tuple-archive"), root.dataHome]
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
