// Run: node --test tests/
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const src = readFileSync(new URL("../Model.js", import.meta.url), "utf8").replace(/^\.pragma library\s*/, "")
const M = {}
vm.runInNewContext(src + "\nObject.assign(out, {" +
  [...src.matchAll(/^function (\w+)/gm)].map((m) => m[1]).join(",") + "})", { out: M })

// Captured verbatim from the v2026_09_16.1 daemon.
const SETTINGS = `overlay | 1 | Show "overlay" annotation window when sharing screen (0|1)
start-calls-muted | 0 | Start with microphone muted when joining a call (0|1)
capture | auto | Screen capture mechanism (auto|x11|portal)
guest-mode | annotation | Current mode in screen window (annotation|control)
transcription-model |  | File path to whisper ggml model
`

const LOG = `17:53:27.226|2464963|2464963|info|version v2026_09_16.1
17:53:27.226|2464963|2464963|info|saved auth token: no
17:53:27.226|2464963|2464963|info|daemon loop started, waiting for events...
17:53:27.227|2464963|2464965|info|Signaler.cpp:137|signaler state changed: suspended -> disconnected
gtk-update-icon-cache: No theme index file.
`

test("parseSettings", () => {
  const s = M.parseSettings(SETTINGS)
  assert.equal(s.length, 5)
  assert.deepEqual(JSON.parse(JSON.stringify(s[0])), { name: "overlay", value: "1", description: 'Show "overlay" annotation window when sharing screen', choices: ["0", "1"], type: "bool" })
  assert.equal(s[2].type, "choice")
  assert.deepEqual([...s[2].choices], ["auto", "x11", "portal"])
  assert.equal(s[4].type, "text")
  assert.equal(s[4].value, "")
  assert.equal(M.nextChoice(s[2]), "x11")
  assert.equal(M.nextChoice({ value: "portal", choices: ["auto", "x11", "portal"] }), "auto")
  assert.equal(M.settingLabel("start-calls-muted"), "Start calls muted")
})

test("parseReply flags daemon errors", () => {
  assert.equal(M.parseReply("can't mute, not in a call\n").ok, false)
  assert.equal(M.parseReply("not logged in\n").ok, false)
  assert.equal(M.parseReply("error: unknown command 'x'\n").message, "error: unknown command 'x'")
  assert.equal(M.parseReply("already not in a call\n").ok, false)
  const ok = M.parseReply("joining call...\ncall connected\n")
  assert.equal(ok.ok, true)
  assert.equal(ok.message, "call connected")
})

test("login + personal url", () => {
  const login = `----\nTuple Login Instructions:\n----\nIf your browser does not open automatically, go to the following URL and login:\n\n    https://production.tuple.app/start?code_challenge=abc&onboarding_origin=app&os=linux\n\nAfter logging in, copy the "authorization code" and run:\n\n    tuple auth AUTHORIZATION_CODE\n`
  assert.equal(M.parseLoginUrl(login), "https://production.tuple.app/start?code_challenge=abc&onboarding_origin=app&os=linux")
  assert.equal(M.parsePersonalUrl("starting new call with personal url...\npersonal url: https://tuple.app/c/ben-123\n"), "https://tuple.app/c/ben-123")
})

test("call urls", () => {
  assert.equal(M.isCallUrl("https://tuple.app/c/abc"), true)
  assert.equal(M.isCallUrl("https://production.tuple.app/c/abc"), true)
  assert.equal(M.isCallUrl("https://tuple.app/c/"), false)
  assert.equal(M.isCallUrl("https://example.com/c/abc"), false)
  assert.equal(M.extractCallUrl("hey join me: https://tuple.app/c/ben-123 thanks"), "https://tuple.app/c/ben-123")
  assert.equal(M.extractCallUrl("<https://tuple.app/c/x>"), "https://tuple.app/c/x")
})

test("contacts + call choices (format from binary strings)", () => {
  const ls = `  101 Alice Smith <alice@x.com> [online] (favorite)\n  102 Bob <bob@x.com> [offline]\n  103 Carol <carol@x.com> [online]\n`
  const c = M.parseContacts(ls)
  assert.deepEqual([...c.map((x) => x.name)], ["Alice Smith", "Carol", "Bob"])
  assert.equal(c[0].favorite, true)
  assert.equal(c[0].online, true)
  assert.equal(c[2].online, false)
  const choices = M.parseCallChoices("  1) Alice Smith <alice@x.com>\n  2) Dan <dan@x.com>\nenter a number: ")
  assert.equal(choices.length, 2)
  assert.equal(M.choiceForContact(choices, c[0]).index, 1)
  assert.equal(M.choiceForContact(choices, c[1]), null)
  assert.equal(M.initials("Alice Smith"), "AS")
  assert.equal(M.presenceLabel("available"), "")
  assert.equal(M.presenceLabel("in call"), "In a call")
  assert.equal(M.presenceLabel("offline"), "")
  assert.equal(M.presenceLabel("unavailable"), "")
})

test("reduceLog: real startup log", () => {
  const s = M.reduceLogText(LOG)
  assert.equal(s.version, "v2026_09_16.1")
  assert.equal(s.tokenSaved, false)
  assert.equal(s.signaler, "disconnected")
  assert.equal(s.call, "idle")
})

test("reduceLog: call lifecycle", () => {
  let s = M.reduceLogText(LOG)
  const feed = (msg) => { s = M.reduceLog(s, M.parseLogLine(`18:00:00.000|2464963|2464963|info|Engine.cpp:1|${msg}`)) }
  feed("signaler state changed: disconnected -> connected")
  assert.equal(M.isSignalerOnline(s.signaler), true)
  feed("received incoming call: Alice")
  assert.equal(s.call, "incoming")
  assert.equal(s.incomingFrom, "Alice")
  feed("peer joined call: Alice")
  assert.equal(s.call, "active")
  assert.deepEqual([...s.peers], ["Alice"])
  feed("local user started sharing screen: 1")
  assert.equal(s.sharing, true)
  feed("peer started sharing screen: Alice")
  assert.equal(s.peerSharing, "Alice")
  feed("peer left call: Alice")
  assert.equal(s.peerSharing, "")
  assert.equal(s.call, "active")
  feed("cli: end")
  assert.equal(s.call, "ending")
  feed("call ended")
  assert.equal(s.call, "idle")
  assert.equal(s.sharing, false)
})

test("reduceLog: daemon restart resets state", () => {
  let s = M.reduceLogText(LOG + "18:00:00.000|2464963|2464963|info|peer joined call: Alice\n")
  assert.equal(s.call, "active")
  s = M.reduceLogText("18:01:00.000|999|999|info|version v2026_09_16.1\n", s)
  assert.equal(s.call, "idle")
  assert.equal(s.pid, "999")
  s = M.reduceLogText("18:02:00.000|999|999|info|Engine.cpp:708|exiting from 'off' command\n", s)
  assert.equal(s.exited, true)
})

test("reduceReply", () => {
  let s = M.emptyState()
  s.call = "active"
  s = M.reduceReply(s, "share", M.parseReply("screen share initiated\n"))
  assert.equal(s.sharing, true)
  s = M.reduceReply(s, "mute", M.parseReply("can't mute, not in a call\n"))
  assert.equal(s.call, "idle")
  assert.equal(s.sharing, false)
})

test("statusLabel", () => {
  const base = { daemon: true, loggedIn: true, call: "active", peers: ["Alice"], incomingFrom: "", signaler: "connected" }
  assert.equal(M.statusLabel(base), "Pairing with Alice")
  assert.equal(M.statusLabel({ ...base, daemon: false }), "Tuple is off")
  assert.equal(M.statusLabel({ ...base, call: "idle" }), "Ready to pair")
  assert.equal(M.statusLabel({ ...base, call: "incoming", incomingFrom: "Bob" }), "Bob is calling")
})

test("large directories: featured + search stay bounded", () => {
  const rows = []
  for (let i = 0; i < 8000; i++) rows.push(`  ${1000 + i} Person ${i} <person${i}@example.com> [offline]`)
  rows.push("  9 Zed Fave <zed@example.com> [offline] (favorite)")
  rows.push("  8 Amy Here <amy@example.com> [available]")
  rows.push("  7 Uma Busy <uma@example.com> [unavailable]")
  const t0 = Date.now()
  const all = M.parseContacts(rows.join("\n"))
  assert.ok(Date.now() - t0 < 500, "parse 8k rows quickly")
  assert.equal(all.length, 8003)
  const featured = M.featuredContacts(all, 30)
  assert.deepEqual([...featured.map((c) => c.name)], ["Amy Here", "Zed Fave"])
  assert.equal(M.searchContacts(all, "person 12", 30).length, 30)
  assert.equal(M.searchContacts(all, "uma", 30)[0].name, "Uma Busy")
  assert.equal(M.searchContacts(all, "", 30).length, 2)
  const counts = M.contactCounts(all)
  assert.equal(counts.favorites, 1)
  assert.equal(counts.online, 1)
  assert.equal(all.find((c) => c.name === "Uma Busy").online, false)
})

// Shapes taken from a real v2026_09_16.1 call log (ids only).
const REAL_CALL = `19:43:45.664|2520219|2520219|info|Engine.cpp:589|cli: ls
19:43:46.198|2520219|2520219|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=0 persist_paint=false)
19:43:46.198|2520219|2520219|info|call connected
19:43:46.198|2520219|2520219|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=0 persist_paint=false)
19:43:46.540|2520219|2803146|info|ContextState: READY
19:43:46.583|2520219|2520219|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=2 persist_paint=true)
19:44:02.779|2520219|2520219|info|Call.cpp:1962|OnVideoCapturerDesktop Start
19:44:32.880|2520219|2520219|info|Engine.cpp:776|WebcamReceivingChange: add peer 162751
19:44:32.880|2520219|2520219|info|webcam: added feed, now 1 feeds
`

test("real call log: peers by id, share, webcam", () => {
  const s = M.reduceLogText(LOG.replace(/2464963/g, "2520219") + REAL_CALL)
  assert.equal(s.call, "active")
  assert.deepEqual([...s.peers], ["162751"])
  assert.equal(s.sharing, true)
  assert.equal(s.peerWebcam, true)
})

test("repeated OnPeerAdded doesn't churn state", () => {
  const s = M.reduceLogText(REAL_CALL)
  const again = M.reduceLog(s, M.parseLogLine("19:45:00.000|2520219|2520219|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=2 persist_paint=true)"))
  assert.equal(again, s)
})

test("`cli: end` with no reply resolves to idle on the next line 3s later (log replay)", () => {
  let s = M.reduceLogText(REAL_CALL + "02:26:20.600|2520219|2520219|info|Engine.cpp:552|cli: end\n")
  assert.equal(s.call, "ending")
  s = M.reduceLogText("02:26:22.000|2520219|2520219|info|Engine.cpp:589|cli: ls\n", s)
  assert.equal(s.call, "ending")
  s = M.reduceLogText("02:26:24.722|2520219|2520219|info|Engine.cpp:589|cli: ls\n", s)
  assert.equal(s.call, "idle")
  assert.equal(s.sharing, false)
  assert.equal(s.peerWebcam, false)
  // A new call after that starts clean.
  s = M.reduceLogText("02:26:30.517|2520219|2520219|info|call connected\n", s)
  assert.equal(s.call, "active")
  assert.deepEqual([...s.peers], [])
})

test("`cli: end` while idle stays idle; ending wraps past midnight", () => {
  let s = M.reduceLogText("23:59:59.000|1|1|info|cli: end\n")
  assert.equal(s.call, "idle")
  s = M.reduceLogText("23:59:59.000|1|1|info|call connected\n23:59:59.500|1|1|info|cli: end\n00:00:05.000|1|1|info|cli: ls\n")
  assert.equal(s.call, "idle")
  assert.equal(M.resolveEnding({ ...M.emptyState(), call: "ending" }).call, "idle")
})

test("audio context teardown and peer removal", () => {
  let s = M.reduceLogText(REAL_CALL + "19:50:00.000|2520219|2520219|info|Engine.cpp:749|EngineEvent: OnPeerRemoved (peer 162751 reason=1 'hung up')\n")
  assert.equal(s.call, "active")
  assert.deepEqual([...s.peers], [])
  s = M.reduceLogText("19:50:00.100|2520219|2803146|info|ContextState: TERMINATED\n", s)
  assert.equal(s.call, "idle")
})

// Today's log: `tuple call` to a favourite who never picked up (ids only).
const UNANSWERED = `16:16:53.823|1120318|1120318|info|Engine.cpp:715|cli: call
16:16:54.107|1120318|1120323|info|Caller.cpp:160|creating offer
16:16:54.108|1120318|1120318|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=0 persist_paint=false)
16:16:54.109|1120318|1120318|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=0 persist_paint=false)
16:17:19.130|1120318|1120323|info|Call.cpp:750|removing peer from call: timeout (connection_state=kNew, exchange_count=0)
16:17:19.130|1120318|1120318|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 162751 cursor_mode=0 persist_paint=false)
16:17:19.132|1120318|1120318|info|Engine.cpp:757|EngineEvent: OnPeerRemoved (peer 162751 reason=timeout '')
16:17:19.132|1120318|1120318|info|peer 162751 removed (Timeout)
16:17:19.133|1120318|1120323|info|Call.cpp:3152|sfu closed
`

test("outgoing call rings (not 'pairing') and ends as unanswered", () => {
  const lines = UNANSWERED.split("\n")
  let s = M.reduceLogText(lines.slice(0, 4).join("\n"))
  assert.equal(s.call, "connecting")
  assert.equal(s.outgoing, true)
  assert.deepEqual([...s.peers], ["162751"])
  assert.equal(M.statusLabel({ daemon: true, loggedIn: true, call: s.call, peers: ["David"], outgoing: s.outgoing }), "Calling David…")
  s = M.reduceLogText(UNANSWERED)
  assert.equal(s.call, "idle")
  assert.equal(s.unanswered, "162751")
  assert.deepEqual([...s.peers], [])
})

test("outgoing call that's answered becomes active", () => {
  let s = M.reduceLogText(UNANSWERED.split("\n").slice(0, 4).join("\n") + "\n16:17:00.000|1120318|1120318|info|call connected\n")
  assert.equal(s.call, "active")
  assert.equal(s.outgoing, false)
  assert.deepEqual([...s.peers], ["162751"])
  s = M.reduceLogText(UNANSWERED.split("\n").slice(0, 4).join("\n") + "\n16:17:00.000|1120318|1120330|info|ContextState: READY\n")
  assert.equal(s.call, "active")
})

test("abandoned `call` prompt resolves via the wall-clock fallback", () => {
  const s = M.reduceLogText("16:16:53.823|1|1|info|Engine.cpp:715|cli: call\n")
  assert.equal(s.call, "connecting")
  assert.equal(M.resolveStaleOutgoing(s).call, "idle")
})

test("parseCameras / resolveCamera / nextCamera", () => {
  const cams = M.parseCameras(`/dev/video50  Hardware ISP Camera (platform:v4l2loopback-050):
/dev/video32  Opal C1: Opal C1 (usb-0000:00:0d.0-2.3):
/dev/video34  Studio Display: Studio Display  (usb-0000:3f:00.0-1.4):
`)
  assert.deepEqual([...cams].map((c) => c.name), ["Hardware ISP Camera", "Opal C1", "Studio Display"])
  assert.deepEqual([...cams].map((c) => c.dev), ["/dev/video50", "/dev/video32", "/dev/video34"])
  assert.equal(M.resolveCamera(cams, "").name, "Hardware ISP Camera")
  assert.equal(M.resolveCamera(cams, "studio display").dev, "/dev/video34")
  assert.equal(M.resolveCamera(cams, "/dev/video32").name, "Opal C1")
  assert.equal(M.resolveCamera(cams, "Unplugged Cam").name, "Hardware ISP Camera")
  assert.equal(M.resolveCamera([], "x"), null)
  assert.equal(M.nextCamera(cams, cams[2]).name, "Hardware ISP Camera")
  assert.equal(M.nextCamera(cams, cams[0]).name, "Opal C1")
})

test("parseMics drops monitors and names the built-in array", () => {
  const mics = M.parseMics(JSON.stringify([
    { name: "alsa_output.usb-x.analog-stereo.monitor", description: "Monitor of X", properties: { "device.class": "monitor" } },
    { name: "alsa_input.pci-0000_00_1f.3-platform-sof_sdw.HiFi__Mic__source", description: "Core Ultra Processors (Series 3) HD Audio Microphones", properties: { "device.class": "sound" } },
    { name: "alsa_input.usb-Opal_Opal_C1-03.analog-stereo", description: "Opal C1 Analog Stereo", properties: { "device.class": "sound" } },
    { name: "alsa_input.usb-teenage_engineering_CM-15-00.mono-fallback", description: "CM-15 Mono", properties: {} }
  ]))
  assert.deepEqual([...mics].map((m) => m.label), ["Built-in microphone", "Opal C1", "CM-15"])
  assert.equal(M.findMic(mics, "alsa_input.usb-Opal_Opal_C1-03.analog-stereo").label, "Opal C1")
  assert.equal(M.findMic(mics, ""), null)
  assert.deepEqual([...M.parseMics("not json")], [])
})

test("findCamera is strict (no fallback), for 'is this the default?'", () => {
  const cams = M.parseCameras("/dev/video50  Hardware ISP Camera (platform:x):\n/dev/video32  Opal C1: Opal C1 (usb-1):\n")
  assert.equal(M.findCamera(cams, ""), null)
  assert.equal(M.findCamera(cams, "Unplugged"), null)
  assert.equal(M.findCamera(cams, "opal c1").dev, "/dev/video32")
})

// From a real v2026_09_16.1 call: they joined via link, turned on their
// webcam, shared their screen, then left.
const LINK_CALL = `17:36:10.214|3823643|3823643|info|call connected
17:37:59.408|3823643|3823649|info|Call.cpp:2374|posting join request
17:37:59.409|3823643|3823643|info|map window: join_request
17:38:07.254|3823643|3823643|info|unmap window: join_request
17:38:07.256|3823643|3823643|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 71792 cursor_mode=0 persist_paint=false)
17:38:24.660|3823643|3823643|info|Engine.cpp:776|WebcamReceivingChange: add peer 71792
17:38:24.661|3823643|3823643|info|map window: webcam
17:39:59.066|3823643|3823643|info|ScreenShareWindow: screen 1920x1080 window-client 1920x1112
17:39:59.067|3823643|3823643|info|map window: screen
`

test("their screen share and join requests come from Tuple's window log", () => {
  const lines = LINK_CALL.split("\n")
  let s = M.reduceLogText(lines.slice(0, 3).join("\n"))
  assert.equal(s.joinRequest, true)
  s = M.reduceLogText(LINK_CALL)
  assert.equal(s.joinRequest, false)
  assert.equal(s.call, "active")
  assert.equal(s.peerWebcam, true)
  assert.equal(s.peerSharing, "71792")
  assert.deepEqual([...s.windows].sort(), ["screen", "webcam"])
  s = M.reduceLogText("18:13:35.889|3823643|3823643|info|unmap window: screen\n18:13:35.889|3823643|3823643|info|unmap window: webcam\n", s)
  assert.equal(s.peerSharing, "")
  assert.deepEqual([...s.windows], [])
})

test("End resolves at once on Tuple's 'invalidating call', not 3s later", () => {
  const s = M.reduceLogText(`17:36:10.214|1|1|info|call connected
17:35:54.838|1|1|info|Engine.cpp:552|cli: end
17:35:54.838|1|2|info|Caller.cpp:985|invalidating call
`)
  assert.equal(s.call, "idle")
})

test("participant joined and everyone-left (Tuple's TODO toasts) are tracked", () => {
  let s = M.reduceLogText(LINK_CALL + "17:38:08.536|1|2|info|Call.cpp:2442|posting participant joined notification\n")
  assert.equal(s.joined, "71792@17:38:08.536")
  s = M.reduceLogText(`18:13:35.889|1|1|info|Engine.cpp:757|EngineEvent: OnPeerRemoved (peer 71792 reason=requested '')
18:13:50.800|1|1|info|TODO: implement HangUpEveryoneLeft notification
`, s)
  assert.equal(s.everyoneLeft, true)
  assert.equal(s.call, "active")
  s = M.reduceLogText("18:14:00.000|1|1|info|Engine.cpp:749|EngineEvent: OnPeerAdded (peer 71792 cursor_mode=0 persist_paint=false)\n", s)
  assert.equal(s.everyoneLeft, false)
})
