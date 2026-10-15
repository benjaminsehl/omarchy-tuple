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
  assert.equal(M.presenceLabel("offline"), "Offline")
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
