.pragma library

// Pure parsing + state helpers for the Tuple Linux client.
//
// How the Tuple Linux client works (v2026_09_16.1):
//
//   * `tuple` is a single static binary. Every invocation is a thin client:
//     it connects to the abstract unix socket `@tuple-daemon`, sends its argv
//     framed as `u64 byteLength, u64 argc, "arg\0arg\0..."`, forwards stdin,
//     prints whatever text the daemon streams back, and exits on EOF.
//   * If no daemon is listening, any invocation spawns one first. The UI must
//     therefore never run a command "just to look" while the daemon is off.
//   * The daemon writes a log to ~/.local/share/tuple/<n>/log.txt, truncated on
//     every daemon start, formatted `HH:MM:SS.mmm|pid|tid|level|message`.
//     That log is the only live event feed (signaler, peers, screen share,
//     incoming calls), so Service.qml tails it and feeds it through
//     reduceLog() below.
//   * There is no status/JSON command. Mic state is never logged, so mute is
//     tracked from command replies.
//
// Keep this file free of QML/Quickshell APIs so it can be unit tested with
// plain node (see tests/model.test.mjs).

var CALL_URL_PREFIXES = ["https://tuple.app/c/", "https://production.tuple.app/c/"]

// ── Command replies ──────────────────────────────────────────────────────

var ERROR_PATTERNS = [
  /^error:/i,
  /^can't /i,
  /^cannot /i,
  /^not logged in/i,
  /^already (logged out|not in a call)/i,
  /failed$/i,
  /^denied$/i,
  /^unknown token/i,
  /^usage:/i
]

function lines(text) {
  return String(text || "").split(/\r?\n/)
}

function nonEmptyLines(text) {
  return lines(text).map(function(l) { return l.replace(/\s+$/, "") }).filter(function(l) { return l.trim() !== "" })
}

function isErrorLine(line) {
  var t = String(line || "").trim()
  for (var i = 0; i < ERROR_PATTERNS.length; i++) if (ERROR_PATTERNS[i].test(t)) return true
  return false
}

// Summarize a finished command: { ok, message, lines }.
// `message` is the most useful single line to surface in the panel.
function parseReply(text) {
  var all = nonEmptyLines(text)
  var errorLine = ""
  for (var i = 0; i < all.length; i++) if (isErrorLine(all[i])) { errorLine = all[i].trim(); break }
  var last = all.length > 0 ? all[all.length - 1].trim() : ""
  return { ok: errorLine === "", message: errorLine || last, lines: all }
}

function firstUrl(text) {
  var m = String(text || "").match(/https?:\/\/[^\s"'<>]+/)
  return m ? m[0] : ""
}

// `tuple new` prints "personal url: https://tuple.app/c/<slug>".
function parsePersonalUrl(text) {
  var m = String(text || "").match(/personal url:\s*(\S+)/i)
  return m ? m[1] : ""
}

// `tuple login` prints a https://production.tuple.app/start?... URL.
function parseLoginUrl(text) {
  var m = String(text || "").match(/https?:\/\/\S*tuple\.app\/start\?\S+/)
  return m ? m[0] : firstUrl(text)
}

function isCallUrl(value) {
  var s = String(value || "").trim()
  for (var i = 0; i < CALL_URL_PREFIXES.length; i++) {
    var p = CALL_URL_PREFIXES[i]
    if (s.indexOf(p) === 0 && s.length > p.length && !/\s/.test(s)) return true
  }
  return false
}

// Pull a call URL out of arbitrary pasted text (e.g. a Slack message).
function extractCallUrl(value) {
  var m = String(value || "").match(/https:\/\/(?:production\.)?tuple\.app\/c\/[^\s"'<>)\]]+/)
  return m ? m[0] : ""
}

// ── Contacts ─────────────────────────────────────────────────────────────

// `tuple ls` rows: "  {id} {name} <{email}> [{status}]{ (favorite)}"
function parseContacts(text) {
  var out = []
  var all = lines(text)
  for (var i = 0; i < all.length; i++) {
    var m = all[i].match(/^\s*(\S+)\s+(.*?)\s*<([^>]*)>\s*\[([^\]]*)\](.*)$/)
    if (!m) continue
    var status = m[4].trim()
    out.push({
      id: m[1],
      name: m[2].trim() || m[3],
      email: m[3].trim(),
      status: status,
      online: isOnlineStatus(status),
      favorite: /favorite/i.test(m[5])
    })
  }
  // Reachable people first, then favorites, then alphabetical.
  out.sort(function(a, b) {
    if (a.online !== b.online) return a.online ? -1 : 1
    if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : (a.name.toLowerCase() > b.name.toLowerCase() ? 1 : 0)
  })
  return out
}

// Words only when they add information beyond the row's fade (unavailable
// people are faded out, so "Offline"/"Unavailable" would just restate it).
function presenceLabel(status) {
  var s = String(status || "").trim().toLowerCase()
  if (s === "" || s === "available" || s === "online" || !isOnlineStatus(s)) return ""
  if (s === "in call") return "In a call"
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function isOnlineStatus(status) {
  var s = String(status || "").trim().toLowerCase()
  if (s === "") return false
  return !/^(off|offline|unavailable|away|inactive|disconnected)\b/.test(s)
}

// Org directories are big (thousands of rows), so the panel never renders the
// full list: by default it shows favorites + anyone available, and a search
// box covers everyone else.
function featuredContacts(contacts, limit) {
  var out = []
  var max = limit || 30
  for (var i = 0; i < contacts.length && out.length < max; i++) {
    var c = contacts[i]
    if (c.favorite || c.online) out.push(c)
  }
  return out
}

function searchContacts(contacts, query, limit) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return featuredContacts(contacts, limit)
  var max = limit || 30
  var starts = []
  var contains = []
  for (var i = 0; i < contacts.length; i++) {
    var c = contacts[i]
    var name = c.name.toLowerCase()
    var email = c.email.toLowerCase()
    if (name.indexOf(q) === 0 || email.indexOf(q) === 0 || name.indexOf(" " + q) !== -1) starts.push(c)
    else if (name.indexOf(q) !== -1 || email.indexOf(q) !== -1) contains.push(c)
    if (starts.length >= max) break
  }
  return starts.concat(contains).slice(0, max)
}

function contactCounts(contacts) {
  var favorites = 0, online = 0, onlineFavorites = 0
  for (var i = 0; i < contacts.length; i++) {
    var c = contacts[i]
    if (c.favorite) favorites++
    if (c.online) online++
    if (c.favorite && c.online) onlineFavorites++
  }
  return { total: contacts.length, favorites: favorites, online: online, onlineFavorites: onlineFavorites }
}

// `tuple call` prompt rows: "  {n}) {name} <{email}>" (online favorites only).
function parseCallChoices(text) {
  var out = []
  var all = lines(text)
  for (var i = 0; i < all.length; i++) {
    var m = all[i].match(/^\s*(\d+)\)\s+(.*?)\s*<([^>]*)>\s*$/)
    if (m) out.push({ index: parseInt(m[1], 10), name: m[2].trim(), email: m[3].trim() })
  }
  return out
}

function choiceForContact(choices, contact) {
  if (!contact) return null
  var email = String(contact.email || "").toLowerCase()
  var name = String(contact.name || "").toLowerCase()
  for (var i = 0; i < choices.length; i++) if (email !== "" && choices[i].email.toLowerCase() === email) return choices[i]
  for (var j = 0; j < choices.length; j++) if (name !== "" && choices[j].name.toLowerCase() === name) return choices[j]
  return null
}

function initials(name) {
  var parts = String(name || "").trim().split(/[\s@._-]+/).filter(function(p) { return p !== "" })
  if (parts.length === 0) return "?"
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}

// ── Settings ─────────────────────────────────────────────────────────────

// `tuple settings` rows: "name | value | Description (a|b|c)"
function parseSettings(text) {
  var out = []
  var all = nonEmptyLines(text)
  for (var i = 0; i < all.length; i++) {
    var parts = all[i].split(" | ")
    if (parts.length < 3) continue
    var name = parts[0].trim()
    if (!/^[a-z0-9][a-z0-9-]*$/i.test(name)) continue
    var value = parts[1].trim()
    var description = parts.slice(2).join(" | ").trim()
    var choices = []
    var cm = description.match(/\(([^()]*\|[^()]*)\)\s*$/)
    if (cm) {
      choices = cm[1].split("|").map(function(c) { return c.trim() }).filter(function(c) { return c !== "" })
      description = description.slice(0, cm.index).trim()
    }
    var type = "text"
    if (choices.length === 2 && choices.indexOf("0") !== -1 && choices.indexOf("1") !== -1) type = "bool"
    else if (choices.length > 0) type = "choice"
    out.push({ name: name, value: value, description: description, choices: choices, type: type })
  }
  return out
}

function settingLabel(name) {
  var s = String(name || "").replace(/-/g, " ")
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function nextChoice(setting) {
  if (!setting || !setting.choices || setting.choices.length === 0) return ""
  var i = setting.choices.indexOf(setting.value)
  return setting.choices[(i + 1) % setting.choices.length]
}

// ── Daemon log → state ───────────────────────────────────────────────────

function emptyState() {
  return {
    pid: "",
    version: "",
    tokenSaved: false,
    signaler: "",
    loggedOut: false,
    exited: false,
    call: "idle",          // idle | connecting | incoming | active | ending
    incomingFrom: "",
    peers: [],             // display names (legacy "peer joined call: X") or contact ids
    sharing: false,
    peerSharing: "",
    peerWebcam: false,
    endingAt: -1,          // log time (s) of `cli: end`; "ending" resolves 3s later
    outgoing: false,       // `cli: call` is ringing someone; peers are callees until it connects
    unanswered: "",        // contact id of the last outgoing call that timed out
    windows: [],           // Tuple windows currently mapped: webcam, screen, join_request, …
    joinRequest: false,    // someone is asking to join your call
    everyoneLeft: false,   // a link call outlived its last peer (Tuple's "hang up?" moment)
    joined: "",            // "<peer>@<time>" of the latest participant-joined event
    lastEvent: "",
    lastEventAt: ""
  }
}

function cloneState(s) {
  return {
    pid: s.pid, version: s.version, tokenSaved: s.tokenSaved, signaler: s.signaler,
    loggedOut: s.loggedOut, exited: s.exited, call: s.call, incomingFrom: s.incomingFrom,
    peers: s.peers.slice(), sharing: s.sharing, peerSharing: s.peerSharing,
    peerWebcam: s.peerWebcam, endingAt: s.endingAt,
    outgoing: s.outgoing, unanswered: s.unanswered,
    windows: s.windows.slice(), joinRequest: s.joinRequest,
    everyoneLeft: s.everyoneLeft, joined: s.joined,
    lastEvent: s.lastEvent, lastEventAt: s.lastEventAt
  }
}

// "17:06:02.861|2340919|2340923|info|Signaler.cpp:366|bound signaler ..."
function parseLogLine(line) {
  var raw = String(line || "")
  var parts = raw.split("|")
  if (parts.length < 5 || !/^\d\d:\d\d:\d\d/.test(parts[0])) return null
  var msg = parts.slice(4).join("|")
  // Strip the optional "File.cpp:123|" source prefix.
  msg = msg.replace(/^[A-Za-z0-9_]+\.(?:cpp|cc|c|h|hpp|zig|mm):\d+\|/, "")
  return { time: parts[0], pid: parts[1], tid: parts[2], level: parts[3], msg: msg.trim() }
}

function addUnique(list, value) {
  var v = String(value || "").trim()
  if (v === "" || list.indexOf(v) !== -1) return list
  var next = list.slice(); next.push(v); return next
}

function removeValue(list, value) {
  var v = String(value || "").trim()
  return list.filter(function(x) { return x !== v })
}

function endCall(s) {
  s.call = "idle"; s.incomingFrom = ""; s.peers = []; s.sharing = false; s.peerSharing = ""
  s.peerWebcam = false; s.endingAt = -1; s.outgoing = false; s.everyoneLeft = false
}

// An outgoing call has been answered.
function connectOutgoing(s) {
  s.call = "active"; s.outgoing = false; s.unanswered = ""
}

// "HH:MM:SS.mmm" → seconds since midnight.
function logSeconds(time) {
  var m = String(time || "").match(/^(\d\d):(\d\d):(\d\d)(?:\.(\d+))?/)
  if (!m) return -1
  return parseInt(m[1], 10) * 3600 + parseInt(m[2], 10) * 60 + parseInt(m[3], 10) + (m[4] ? parseFloat("0." + m[4]) : 0)
}

function secondsSince(from, time) {
  var now = logSeconds(time)
  if (from < 0 || now < 0) return 0
  var d = now - from
  return d < 0 ? d + 86400 : d
}

// Seconds after `cli: end` with no "call ended" before we call it ended.
// The daemon's own end is synchronous; this only covers ends issued by
// other clients and log replays (which never see the command's reply).
var ENDING_GRACE = 3

function isSignalerOnline(state) {
  return /^(connected|ready|online|authenticated)/i.test(String(state || ""))
}

// Fold one parsed log entry into the state. Returns a new object; never
// mutates the input (so QML property bindings see a change).
function reduceLog(state, entry) {
  if (!entry) return state
  var s = cloneState(state || emptyState())
  var msg = entry.msg
  var m

  if (s.pid !== "" && entry.pid !== s.pid && /^version v/.test(msg)) {
    s = emptyState()
  }
  if (s.pid === "") s.pid = entry.pid

  var resolved = false
  if (s.call === "ending" && secondsSince(s.endingAt, entry.time) > ENDING_GRACE) { endCall(s); resolved = true }

  if (/^cli: call\b/.test(msg)) {
    // `tuple call` rings a favourite. The engine adds them as a peer right
    // away (before they answer), so stay "connecting" until the call does.
    if (s.call !== "idle") return resolved ? finishEntry(s, entry) : state
    s.call = "connecting"; s.outgoing = true; s.unanswered = ""; s.peers = []
  } else if ((m = msg.match(/^EngineEvent: OnPeerAdded \(peer (\S+)/))) {
    if (s.outgoing && s.call === "connecting") {
      if (!resolved && s.peers.indexOf(m[1]) !== -1) return state
      s.peers = addUnique(s.peers, m[1])
      return finishEntry(s, entry)
    }
    // An incoming call adds the caller as a peer while their prompt is still
    // up; stay "incoming" until it's answered.
    if (s.call === "incoming") {
      if (!resolved && s.peers.indexOf(m[1]) !== -1) return state
      s.peers = addUnique(s.peers, m[1])
      return finishEntry(s, entry)
    }
    // Logged many times per peer; don't churn state for repeats.
    if (!resolved && s.call === "active" && s.peers.indexOf(m[1]) !== -1) return state
    s.call = "active"; s.incomingFrom = ""; s.endingAt = -1; s.peers = addUnique(s.peers, m[1])
    s.everyoneLeft = false
  } else if ((m = msg.match(/^EngineEvent: OnPeerRemoved \(peer (\S+)(.*)$/))) {
    if (s.outgoing && s.call === "connecting") {
      // Nobody picked up: the engine gives up after ~25s (reason=timeout).
      endCall(s); s.peers = []
      if (/reason=timeout/.test(m[2])) s.unanswered = m[1]
      return finishEntry(s, entry)
    }
    if (!resolved && s.peers.indexOf(m[1]) === -1) return state
    s.peers = removeValue(s.peers, m[1])
    if (s.peerSharing === m[1]) s.peerSharing = ""
  } else if ((m = msg.match(/^(map|unmap) window: (\S+)/))) {
    // Tuple's own windows. "screen" is *their* shared screen (yours is
    // OnVideoCapturerDesktop); "join_request" asks you to let someone in.
    var role = m[2]
    var mapped = m[1] === "map"
    if (!resolved && mapped === (s.windows.indexOf(role) !== -1)) return state
    s.windows = mapped ? addUnique(s.windows, role) : removeValue(s.windows, role)
    if (role === "screen") s.peerSharing = mapped ? (s.peers.length === 1 ? s.peers[0] : "peer") : ""
    if (role === "join_request") s.joinRequest = mapped
  } else if (/^posting join request/.test(msg)) {
    s.joinRequest = true
  } else if (/^posting participant joined notification/.test(msg)) {
    // Tuple's own toast for this is a TODO on Linux; the panel posts one.
    s.joined = (s.peers.length > 0 ? s.peers[s.peers.length - 1] : "") + "@" + entry.time
  } else if (/^TODO: implement HangUpEveryoneLeft notification/.test(msg)) {
    if (s.call !== "active" || s.peers.length > 0) return resolved ? finishEntry(s, entry) : state
    s.everyoneLeft = true
  } else if (/^TODO: implement dismiss HangUpEveryoneLeft/.test(msg)) {
    if (!s.everyoneLeft) return resolved ? finishEntry(s, entry) : state
    s.everyoneLeft = false
  } else if (/^invalidating call/.test(msg) || (/^sfu closed/.test(msg) && s.call === "ending")) {
    // Logged straight after `cli: end` (ours or another client's): the call
    // is over, no need to wait out the ending grace period.
    if (s.call === "idle") return resolved ? finishEntry(s, entry) : state
    endCall(s); s.peers = []
  } else if (/^sfu closed/.test(msg) && s.outgoing) {
    endCall(s); s.peers = []
  } else if ((/^ContextState: READY/.test(msg) || /^peer connection state changed: \S+ -> kConnected/.test(msg)) && s.outgoing) {
    connectOutgoing(s)
  } else if (/^OnVideoCapturerDesktop Start/.test(msg)) {
    if (!resolved && s.sharing) return state
    s.sharing = true
  } else if (/^OnVideoCapturerDesktop Stop/.test(msg)) {
    if (!resolved && !s.sharing) return state
    s.sharing = false
  } else if (/^(webcam: added feed|WebcamReceivingChange: add)/.test(msg)) {
    if (!resolved && s.peerWebcam) return state
    s.peerWebcam = true
  } else if (/^(webcam: removed feed, now 0|WebcamReceivingChange: remove)/.test(msg)) {
    if (!resolved && !s.peerWebcam) return state
    s.peerWebcam = false
  } else if ((m = msg.match(/^version (v\S+)/))) {
    s = emptyState(); s.pid = entry.pid; s.version = m[1]
  } else if ((m = msg.match(/^saved auth token: (\w+)/))) {
    s.tokenSaved = /^(yes|true|1)$/i.test(m[1])
  } else if ((m = msg.match(/^signaler state changed: (\S+) -> (\S+)/))) {
    s.signaler = m[2]
  } else if (/^logout initiated|^auth token deleted|^logged out/i.test(msg)) {
    s.tokenSaved = false; s.loggedOut = true; endCall(s)
  } else if (/^(login succeeded|logged in|saved auth token$|stored auth token)/i.test(msg)) {
    s.tokenSaved = true; s.loggedOut = false
  } else if ((m = msg.match(/^received incoming call: (.*)$/))) {
    // Tuple logs the call's id here, not who's calling; the caller arrives
    // as a peer right after.
    if (s.call === "idle") { s.call = "incoming"; s.peers = [] }
    var from = m[1].trim()
    s.incomingFrom = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(from) ? "" : from
  } else if ((m = msg.match(/^resolving incoming call: (\S+)/))) {
    if (s.call !== "incoming") return resolved ? finishEntry(s, entry) : state
    if (m[1] === "accept") { s.call = "active"; s.incomingFrom = "" } else endCall(s)
  } else if (/^(denying incoming call|incoming call already rejected)/.test(msg)) {
    if (s.call === "incoming") endCall(s)
    s.incomingFrom = ""
  } else if ((m = msg.match(/^peer joined call: (.*)$/))) {
    s.call = "active"; s.incomingFrom = ""; s.peers = addUnique(s.peers, m[1])
  } else if ((m = msg.match(/^peer left call: (.*)$/))) {
    s.peers = removeValue(s.peers, m[1])
    if (s.peerSharing === m[1].trim()) s.peerSharing = ""
  } else if (/^local user started sharing screen/.test(msg)) {
    s.sharing = true
  } else if (/^local user stopped sharing screen/.test(msg)) {
    s.sharing = false
  } else if ((m = msg.match(/^peer started sharing screen: (.*)$/))) {
    s.peerSharing = m[1].trim() || "peer"
  } else if (/^peer stopped sharing screen/.test(msg)) {
    s.peerSharing = ""
  } else if (/^(call connected|answering call with)/.test(msg)) {
    connectOutgoing(s); s.incomingFrom = ""
  } else if (/^(joining call|call connecting|calling |starting new call|connecting)/i.test(msg)) {
    if (s.call === "idle") s.call = "connecting"
  } else if (/^cli: end\b/.test(msg)) {
    if (s.call === "idle" || s.call === "ending") return resolved ? finishEntry(s, entry) : state
    s.call = "ending"; s.endingAt = logSeconds(entry.time)
  } else if (/^(call ended|call failed|pending call cancelled|pending 'new' call cancelled|cancelled pending join call|call was asked to hang up remotely|call was resolved remotely|received reversed hang up message|current user is no longer authorized; resetting call state|exiting from 'off' command after call ended)/.test(msg)
      || /^ContextState: (TERMINATED|FAILED)/.test(msg)) {
    // ContextState is the per-call PulseAudio context: created as the call
    // connects, torn down when it ends.
    if (s.call === "idle" && !resolved) return state
    endCall(s)
  } else if (/^(exiting|disconnect \(GracefulShutdown\)|tuple is no longer running)/.test(msg)) {
    endCall(s); s.exited = true; s.signaler = ""
  } else {
    return resolved ? finishEntry(s, entry) : state
  }

  return finishEntry(s, entry)
}

function finishEntry(s, entry) {
  s.lastEvent = entry.msg
  s.lastEventAt = entry.time
  return s
}

// Wall-clock fallback for a live "ending" that the log never resolves.
function resolveEnding(state) {
  if (!state || state.call !== "ending") return state
  var s = cloneState(state); endCall(s); return s
}

// Wall-clock fallback for an outgoing ring the log never resolves (e.g. the
// `call` prompt was abandoned before anyone was dialled).
function resolveStaleOutgoing(state) {
  if (!state || !state.outgoing || state.call !== "connecting" || state.peers.length > 0) return state
  var s = cloneState(state); endCall(s); return s
}

function reduceLogText(text, state) {
  var s = state || emptyState()
  var all = lines(text)
  for (var i = 0; i < all.length; i++) s = reduceLog(s, parseLogLine(all[i]))
  return s
}

// The command reply is the most reliable signal for our own actions; fold it
// into the state too so the UI doesn't wait for (or depend on) log lines.
function reduceReply(state, command, reply) {
  var s = cloneState(state || emptyState())
  var text = reply.lines.join("\n")
  if (/not in a call|already not in a call/i.test(text)) endCall(s)
  if (!reply.ok) return s
  if (command === "share") s.sharing = true
  else if (command === "unshare") s.sharing = false
  else if (command === "end") endCall(s)
  else if (command === "logout") { s.tokenSaved = false; s.loggedOut = true; endCall(s) }
  else if (command === "auth") { s.tokenSaved = true; s.loggedOut = false }
  else if (command === "off") { endCall(s); s.exited = true; s.signaler = "" }
  if (/call connected/i.test(text)) s.call = "active"
  if (/call ended/i.test(text)) endCall(s)
  return s
}

function statusLabel(st) {
  if (!st.daemon) return "Tuple is off"
  if (!st.loggedIn) return "Not logged in"
  if (st.call === "incoming") return st.incomingFrom !== "" ? st.incomingFrom + " is calling" : "Incoming call"
  if (st.call === "connecting") {
    if (st.outgoing && st.peers.length === 1) return "Calling " + st.peers[0] + "…"
    return st.outgoing ? "Calling…" : "Connecting…"
  }
  if (st.call === "ending") return "Ending call…"
  if (st.call === "active") {
    if (st.peers.length === 0) return "Waiting for someone to join"
    if (st.peers.length === 1) return "Pairing with " + st.peers[0]
    return "Pairing with " + st.peers.length + " people"
  }
  if (st.signaler !== "" && !isSignalerOnline(st.signaler)) return "Signaler " + st.signaler
  return "Ready to pair"
}

// ── Cameras ──────────────────────────────────────────────────────────────

// `omarchy-capture-webcam-list` prints one capture device per line:
//   "/dev/video34  Studio Display: Studio Display  (usb-0000:3f:00.0-1.4):"
// The name drops v4l2's bus suffix and its "Model: Model" repetition.
function parseCameras(text) {
  var out = []
  var all = nonEmptyLines(text)
  for (var i = 0; i < all.length; i++) {
    var m = all[i].match(/^(\/dev\/\S+)\s+(.*)$/)
    if (!m) continue
    var name = m[2].replace(/:\s*$/, "").replace(/\s*\([^()]*\)\s*$/, "").trim()
    var halves = name.match(/^(.+?):\s*(.+)$/)
    if (halves && halves[1].trim() === halves[2].trim()) name = halves[1].trim()
    out.push({ dev: m[1], name: name || m[1] })
  }
  return out
}

// The saved preference is a camera name (stable across reboots and replugs,
// unlike /dev/videoN) or, for older settings, a device path. Falls back to
// the first camera when the preferred one isn't plugged in.
function resolveCamera(cameras, preference) {
  var list = cameras || []
  var pref = String(preference || "").trim()
  if (pref !== "") {
    for (var i = 0; i < list.length; i++) if (list[i].dev === pref) return list[i]
    var lower = pref.toLowerCase()
    for (var j = 0; j < list.length; j++) if (list[j].name.toLowerCase() === lower) return list[j]
  }
  return list.length > 0 ? list[0] : null
}

function nextCamera(cameras, current) {
  var list = cameras || []
  if (list.length === 0) return null
  var dev = current ? current.dev : ""
  for (var i = 0; i < list.length; i++) if (list[i].dev === dev) return list[(i + 1) % list.length]
  return list[0]
}

function findCamera(cameras, preference) {
  var list = cameras || []
  var pref = String(preference || "").trim()
  if (pref === "") return null
  for (var i = 0; i < list.length; i++) if (list[i].dev === pref) return list[i]
  var lower = pref.toLowerCase()
  for (var j = 0; j < list.length; j++) if (list[j].name.toLowerCase() === lower) return list[j]
  return null
}

// ── Microphones ──────────────────────────────────────────────────────────

// `pactl -f json list sources` → real inputs only (no sink monitors).
function parseMics(json) {
  var all
  try { all = JSON.parse(String(json || "").trim() || "[]") } catch (e) { return [] }
  var out = []
  for (var i = 0; i < all.length; i++) {
    var src = all[i] || {}
    var props = src.properties || {}
    var name = String(src.name || "")
    if (name === "" || /\.monitor$/.test(name) || props["device.class"] === "monitor") continue
    var label = String(src.description || props["device.description"] || name)
      .replace(/\s+(Analog Stereo|Mono|Stereo|Multichannel Input)$/i, "")
    // The laptop's own array reports as the audio chipset ("Core Ultra … HD
    // Audio Microphones"); call it what it is.
    if (/^alsa_input\.pci-/.test(name) && /microphone/i.test(label)) label = "Built-in microphone"
    out.push({ name: name, label: label })
  }
  return out
}

function findMic(mics, name) {
  var list = mics || []
  var n = String(name || "")
  if (n === "") return null
  for (var i = 0; i < list.length; i++) if (list[i].name === n) return list[i]
  return null
}
