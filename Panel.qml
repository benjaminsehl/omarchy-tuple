import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Design notes — "as little design as possible":
//   * The hero states where you are; sections don't restate it.
//   * One control per intent: a single field+button starts or joins a call.
//   * Presence is shown once: unavailable people are faded; words only when
//     they add something (e.g. "In a call").
//   * Secondary actions (favorite, call) appear on the row you're pointing at.
//   * Keyboard shortcuts exist but aren't printed; see README / tooltips.
Panel {
  id: root
  moduleName: "sehl.tuple"
  ipcTarget: "sehl.tuple"
  manageIpc: false

  // ── Look ──────────────────────────────────────────────────────────────
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // Depth from the theme's [material]; flat unless the theme asks for it.
  Material { id: depthTheme }

  readonly property color barIconColor: {
    if (!tuple.installed || !tuple.daemon || !tuple.loggedIn) return Qt.darker(barForeground, 1.55)
    if (tuple.incoming) return urgent
    if (tuple.inCall) return tuple.muted ? Qt.darker(urgent, 1.5) : urgent
    return barForeground
  }

  // ── State ─────────────────────────────────────────────────────────────
  property bool cursorActive: false
  property string cursorKey: "daemon"
  property bool settingsOpen: false
  property string authCode: ""
  property string joinText: ""
  property string contactQuery: ""
  readonly property int contactLimit: 40
  readonly property bool joinable: Model.extractCallUrl(joinText) !== ""
  readonly property bool showPair: tuple.loggedIn && !tuple.inCall && !tuple.incoming
  // Never bind a Repeater to the full directory (orgs have thousands of
  // people); show available + favorites, or the top search matches.
  readonly property var shownContacts: Model.searchContacts(tuple.contacts, contactQuery, contactLimit)
  readonly property bool peopleHints: tuple.loggedIn && (shownContacts.length === 0
    || (contactQuery !== "" && shownContacts.length >= contactLimit))
  // With nothing below it, the people list runs through the panel's bottom
  // padding to the edge and scrolls under it.
  readonly property bool peopleBleed: tuple.loggedIn && shownContacts.length > 0 && !peopleHints
  readonly property var headerKeys: ["daemon", "settings"]
  readonly property var tileKeys: ["answer", "decline", "mute", "share", "camera", "copyLink", "end"]

  readonly property var navKeys: {
    var keys = []
    if (tuple.installed) keys.push("daemon")
    if (!tuple.installed || !tuple.daemon) return keys
    if (tuple.loggedIn) {
      keys.push("settings")
      if (settingsOpen) for (var j = 0; j < tuple.tupleSettings.length; j++) keys.push("setting:" + tuple.tupleSettings[j].name)
    }
    if (!tuple.loggedIn) {
      keys.push("login")
      if (tuple.loginUrl !== "") keys.push("loginUrl")
      if (tuple.loginPending || tuple.loginUrl !== "") keys.push("auth")
      return keys
    }
    if (tuple.incoming) { keys.push("answer"); keys.push("decline") }
    if (tuple.inCall) {
      if (tuple.log.peerSharing !== "") { keys.push("control"); keys.push("viewScreen") }
      keys.push("mute"); keys.push("share"); keys.push("camera")
      if (tuple.personalUrl !== "") keys.push("copyLink")
      keys.push("end")
    }
    if (showPair) keys.push("pair")
    if (searchField.visible) keys.push("search")
    for (var i = 0; i < shownContacts.length; i++) keys.push("contact:" + shownContacts[i].id)
    return keys
  }

  function hasCursor(key) { return cursorActive && cursorKey === key }
  function hover(key) { cursorActive = true; cursorKey = key }

  function moveCursor(dx, dy) {
    var horizontal = headerKeys.indexOf(cursorKey) !== -1 || tileKeys.indexOf(cursorKey) !== -1
    if (dx !== 0 && horizontal) dy = dx
    if (dy === 0) return
    var i = navKeys.indexOf(cursorKey)
    // Vertical moves skip across a horizontal group in one step.
    if (dx === 0 && horizontal) {
      var group = headerKeys.indexOf(cursorKey) !== -1 ? headerKeys : tileKeys
      while (i + dy >= 0 && i + dy < navKeys.length && group.indexOf(navKeys[i + dy]) !== -1) i += dy
    }
    i = i === -1 ? 0 : Math.max(0, Math.min(navKeys.length - 1, i + dy))
    cursorKey = navKeys[i] || "daemon"
    scrollToCursor()
  }

  function contactById(id) {
    for (var i = 0; i < tuple.contacts.length; i++) if (tuple.contacts[i].id === id) return tuple.contacts[i]
    return null
  }

  function settingByName(name) {
    for (var i = 0; i < tuple.tupleSettings.length; i++) if (tuple.tupleSettings[i].name === name) return tuple.tupleSettings[i]
    return null
  }

  function pair() {
    if (joinable) { tuple.join(joinText); joinText = "" }
    else if (joinText.trim() !== "") tuple.join(joinText)   // surfaces the "not a call link" error
    else tuple.newCall()
  }

  function activate(key) {
    if (key === "daemon") tuple.toggleDaemon()
    else if (key === "login") tuple.login()
    else if (key === "loginUrl") tuple.openUrl(tuple.loginUrl)
    else if (key === "auth") focusField(authField)
    else if (key === "answer") tuple.answer()
    else if (key === "decline") tuple.decline()
    else if (key === "mute") tuple.toggleMute()
    else if (key === "share") tuple.toggleShare()
    else if (key === "camera") tuple.toggleCamera()
    else if (key === "control") tuple.setGuestMode(tuple.guestMode === "control" ? "annotation" : "control")
    else if (key === "viewScreen") tuple.viewScreen()
    else if (key === "copyLink") tuple.copy(tuple.personalUrl, "Call link")
    else if (key === "end") tuple.endCall()
    else if (key === "pair") pair()
    else if (key === "search") focusField(searchField)
    else if (key === "settings") settingsOpen = !settingsOpen
    else if (key.indexOf("contact:") === 0) callFromKeyboard(contactById(key.slice(8)))
    else if (key.indexOf("setting:") === 0) cycleSetting(settingByName(key.slice(8)))
  }

  // The split half of the Mic and Camera tiles: pick an input, or follow the
  // system default.
  function openDeviceMenu(kind, tile) {
    if (deviceMenu.opened && deviceMenu.kind === kind) { deviceMenu.close(); return }
    var anchor = tile || (kind === "mic" ? micTile : cameraTile)
    if (kind === "mic") tuple.refreshMics(); else tuple.refreshCameras()
    deviceMenu.kind = kind
    deviceMenu.anchorTile = anchor
    deviceMenu.open()
  }

  readonly property var micOptions: {
    var opts = [{ value: "", label: "System default", detail: tuple.defaultMic !== "" ? (Model.findMic(tuple.mics, tuple.defaultMic) || { label: "" }).label : "" }]
    for (var i = 0; i < tuple.mics.length; i++) opts.push({ value: tuple.mics[i].name, label: tuple.mics[i].label, detail: "" })
    return opts
  }

  readonly property var cameraOptions: {
    var opts = [{ value: "", label: "System default", detail: tuple.cameras.length > 0 ? tuple.cameras[0].name : "" }]
    for (var i = 0; i < tuple.cameras.length; i++) opts.push({ value: tuple.cameras[i].name, label: tuple.cameras[i].name, detail: "" })
    return opts
  }

  function callFromKeyboard(contact) {
    if (!contact) return
    if (tuple.inCall || tuple.incoming) { tuple.say("You're already in a call", true); return }
    if (!contact.online) { tuple.say(contact.name + " isn't available", true); return }
    tuple.callContact(contact)
  }

  function cycleSetting(s) {
    if (!s || s.type === "text") return
    tuple.setTupleSetting(s.name, Model.nextChoice(s))
  }

  function focusField(field) {
    cursorActive = true
    Qt.callLater(function() { field.forceActiveFocus() })
  }

  function refocusKeys() { Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }

  function scrollToCursor() {
    Qt.callLater(function() {
      // Only rows in the people list can be out of view.
      var item = findNavItem(peopleColumn, cursorKey)
      if (!item) return
      var f = peopleFlick
      f.cancelFlick()
      var top = item.mapToItem(f.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, f.contentHeight - f.height)
      if (top < f.contentY) f.contentY = Math.max(0, top)
      else if (bottom > f.contentY + f.height) f.contentY = Math.min(maxY, bottom - f.height)
    })
  }

  function findNavItem(item, key) {
    if (!item) return null
    if (item.navKey === key && item.visible) return item
    var kids = item.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = findNavItem(kids[i], key)
      if (found) return found
    }
    return null
  }

  function firstContentKey() {
    for (var i = 0; i < navKeys.length; i++) if (navKeys[i] !== "daemon") return navKeys[i]
    return "daemon"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorKey = firstContentKey()
      if (peopleFlick) peopleFlick.contentY = 0
      tuple.refresh()
      refocusKeys()
    } else {
      joinText = ""
      contactQuery = ""
    }
  }
  onNavKeysChanged: if (navKeys.indexOf(cursorKey) === -1) cursorKey = firstContentKey()

  Service {
    id: tuple
    settings: root.settings
    onSettingsChangeRequested: function(values) { root.persistSettings(values) }
  }

  // Same pattern as Omarchy's own panels: update the local copy so bindings
  // move now, then write the bar entry so it survives a restart.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // A call link on the clipboard is almost certainly the one you're about to
  // join — put it in the field so the button reads "Join".
  Connections {
    target: tuple
    function onClipboardCallUrlChanged() {
      if (root.opened && root.joinText === "" && tuple.clipboardCallUrl !== "") root.joinText = tuple.clipboardCallUrl
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { tuple.refresh(true); return "ok" }
    function on(): string { tuple.turnOn(); return "ok" }
    function off(): string { tuple.turnOff(); return "ok" }
    function newCall(): string { tuple.newCall(); return "ok" }
    function join(url: string): string { tuple.join(url); return "ok" }
    function joinClipboard(): string { tuple.readClipboard(); joinLater.restart(); return "ok" }
    function mute(): string { tuple.setMuted(true); return "ok" }
    function unmute(): string { tuple.setMuted(false); return "ok" }
    function toggleMute(): string { tuple.toggleMute(); return "ok" }
    function share(): string { tuple.setSharing(true); return "ok" }
    function unshare(): string { tuple.setSharing(false); return "ok" }
    function toggleShare(): string { tuple.toggleShare(); return "ok" }
    function toggleCamera(): string { tuple.toggleCamera(); return tuple.cameraOn ? "on" : "off" }
    function cameras(): string {
      tuple.refreshCameras()
      return tuple.cameras.map(function(c, i) {
        return (i + 1) + ") " + c.name + "  " + c.dev + (tuple.camera && tuple.camera.dev === c.dev ? "  (selected)" : "")
      }).join("\n")
    }
    function camera(query: string): string { tuple.selectCamera(query); return tuple.camera ? tuple.camera.name : "" }
    function cycleCamera(): string { tuple.cycleCamera(); return tuple.camera ? tuple.camera.name : "" }
    function mics(): string {
      tuple.refreshMics()
      return tuple.mics.map(function(m, i) {
        return (i + 1) + ") " + m.label + "  " + m.name + (m.name === tuple.defaultMic ? "  (system default)" : "") + (!tuple.micIsDefault && tuple.mic && tuple.mic.name === m.name ? "  (selected)" : "")
      }).join("\n")
    }
    function deviceMenu(kind: string): string {
      if (!tuple.inCall) return "not in a call"
      root.open()
      Qt.callLater(function() { root.openDeviceMenu(kind === "camera" ? "camera" : "mic") })
      return "ok"
    }
    function mic(query: string): string { tuple.selectMic(query); return tuple.micIsDefault ? "default" : (tuple.mic ? tuple.mic.label : "") }
    function end(): string { tuple.endCall(); return "ok" }
    function demo(scenario: string): string { return tuple.setDemo(scenario) }
    function copyLink(): string { tuple.copy(tuple.personalUrl, "Call link"); return tuple.personalUrl }
    function status(): string {
      return JSON.stringify({
        installed: tuple.installed, daemon: tuple.daemon, loggedIn: tuple.loggedIn,
        call: tuple.call, peers: tuple.peerNames, peerIds: tuple.peers, muted: tuple.muted, sharing: tuple.sharing,
        peerWebcam: tuple.log.peerWebcam, camera: tuple.cameraOn,
        cameraDevice: tuple.cameraIsDefault ? "default" : (tuple.camera ? tuple.camera.name : ""),
        micDevice: tuple.micIsDefault ? "default" : (tuple.mic ? tuple.mic.label : ""), lastEvent: tuple.log.lastEvent,
        incomingFrom: tuple.log.incomingFrom, signaler: tuple.log.signaler,
        version: tuple.log.version, personalUrl: tuple.personalUrl, text: tuple.statusText
      })
    }
  }

  Timer { id: joinLater; interval: 300; onTriggered: if (tuple.clipboardCallUrl !== "") tuple.join(tuple.clipboardCallUrl) }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Tuple — " + tuple.statusText + (tuple.inCall ? (tuple.muted ? " · muted" : "") + (tuple.sharing ? " · sharing" : "") : "")
    iconComponent: Component {
      Item {
        TupleIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: tuple.sharing ? root.barForeground : root.urgent
          badge: tuple.sharing ? "sharing" : (tuple.daemon && tuple.auth === 0 ? "warning" : "")
          crossed: tuple.installed && !tuple.daemon
          pulsing: tuple.incoming
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (tuple.inCall) tuple.toggleMute()
        else if (tuple.incoming) tuple.answer()
        else root.toggle()
      } else if (b === Qt.MiddleButton) {
        if (tuple.inCall) tuple.toggleShare()
        else tuple.refresh(true)
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight - (root.peopleBleed ? panel.padding : 0), Style.space(600))

    CardShadow { material: depthTheme }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: pairField.activeFocus || authField.activeFocus || searchField.activeFocus || deviceMenu.opened
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.cursorKey)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "M" && tuple.inCall) { root.openDeviceMenu("mic"); return }
        if (t === "V" && tuple.inCall) { root.openDeviceMenu("camera"); return }
        var k = t.toLowerCase()
        if (k === "m" && tuple.inCall) tuple.toggleMute()
        else if (k === "s" && tuple.inCall) tuple.toggleShare()
        else if (k === "v" && tuple.inCall) tuple.toggleCamera()
        else if (k === "e" && (tuple.inCall || tuple.incoming)) tuple.endCall()
        else if (k === "a" && tuple.incoming) tuple.answer()
        else if (k === "n" && root.showPair) tuple.newCall()
        else if (k === "c" && tuple.personalUrl !== "") tuple.copy(tuple.personalUrl, "Call link")
        else if (k === "i" && root.showPair) root.focusField(pairField)
        else if (k === "/" && tuple.contacts.length > 0) root.focusField(searchField)
        else if (k === "f" && root.cursorKey.indexOf("contact:") === 0) tuple.toggleFavorite(root.contactById(root.cursorKey.slice(8)))
        else if (k === "o") tuple.toggleDaemon()
        else if (k === "r") tuple.refresh(true)
      }

      // Only the people list scrolls. Everything above it (status, settings,
      // call controls, the join field, search) and below it (hints) stays
      // put; the list takes whatever height is left and shrinks first when
      // the panel is capped by the screen.
      ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.bottomMargin: root.peopleBleed ? -panel.padding : 0
        spacing: 0

        Column {
          id: topColumn
          Layout.fillWidth: true
          Layout.preferredHeight: implicitHeight
          Layout.minimumHeight: implicitHeight
          Layout.maximumHeight: implicitHeight
          spacing: Style.space(12)

          // ── Hero ──────────────────────────────────────────────────────
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.hasCursor("daemon")
            property string navKey: "daemon"

            PanelHero {
              id: hero
              width: parent.width
              title: "Tuple"
              meta: tuple.statusText
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: tuple.daemon ? 1.0 : 0.5
              iconComponent: Component {
                TupleIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  badgeColor: root.urgent
                  badge: tuple.inCall && !tuple.muted ? "live" : ""
                  crossed: !tuple.daemon
                  pulsing: tuple.incoming
                }
              }
              trailingControl: Component {
                Row {
                  spacing: Style.space(8)

                  ToggleSwitch {
                    id: powerSwitch
                    visible: tuple.installed
                    anchors.verticalCenter: parent.verticalCenter
                    checked: tuple.daemon
                    busy: tuple.isPending("on") || tuple.isPending("off")
                    hasCursor: header.ringVisible
                    foreground: hero.foreground
                    onHovered: function(on) { if (on) root.hover("daemon") }
                    onToggled: tuple.toggleDaemon()

                    PanelToolTip {
                      visible: powerSwitch.containsMouse
                      text: tuple.daemon ? "Turn off — you won't receive calls" : "Turn on to pair and receive calls"
                      fontFamily: hero.fontFamily
                    }
                  }

                  PanelActionButton {
                    visible: tuple.daemon && tuple.loggedIn
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰒓"
                    tooltipText: root.settingsOpen ? "Hide settings" : "Settings"
                    hasCursor: root.hasCursor("settings") || root.settingsOpen
                    foreground: hero.foreground
                    fontFamily: hero.fontFamily
                    onHovered: function(on) { if (on) root.hover("settings") }
                    onClicked: root.settingsOpen = !root.settingsOpen
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: tuple.lastError !== "" ? tuple.lastError : tuple.actionStatus
            color: tuple.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // ── Settings (the gear in the hero) ─────────────────────────────
          Column {
            visible: tuple.loggedIn && root.settingsOpen && tuple.tupleSettings.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.settingsOpen ? tuple.tupleSettings : []
              SettingRow {
                required property var modelData
                width: parent.width
                setting: modelData
              }
            }

            PanelSeparator { foreground: root.foreground }
          }

          Hint {
            visible: !tuple.installed
            text: "The tuple CLI isn't on your PATH. Install it from tuple.app/linux."
          }

          // ── Login ─────────────────────────────────────────────────────
          Column {
            visible: tuple.daemon && !tuple.loggedIn
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }

            ActionRow {
              navKey: "login"
              glyph: "󰍂"
              title: tuple.loginUrl !== "" ? "Restart login" : "Log in"
              subtitle: "Continues in your browser"
              spinning: tuple.isPending("login")
              onActivated: tuple.login()
            }

            ActionRow {
              visible: tuple.loginUrl !== ""
              navKey: "loginUrl"
              glyph: "󰌹"
              title: "Open the login page again"
              subtitle: tuple.loginUrl
              trailingGlyph: "󰆏"
              onActivated: tuple.openUrl(tuple.loginUrl)
              onTrailingClicked: tuple.copy(tuple.loginUrl, "Login link")
            }

            RowLayout {
              visible: tuple.loginPending || tuple.loginUrl !== ""
              width: parent.width
              spacing: Style.space(8)
              property string navKey: "auth"

              WellField {
                id: authField
                Layout.fillWidth: true
                foreground: root.foreground
                hasCursor: root.hasCursor("auth")
                placeholderText: "Authorization code"
                text: root.authCode
                onTextChanged: root.authCode = text
                onAccepted: { tuple.submitAuth(text); root.authCode = ""; root.refocusKeys() }
                Keys.onEscapePressed: root.refocusKeys()
              }

              KeyButton {
                text: "Log in"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.preferredHeight: authField.height
                enabled: root.authCode.trim() !== "" && !tuple.isPending("auth")
                onClicked: { tuple.submitAuth(root.authCode); root.authCode = "" }
              }
            }
          }

          // ── Incoming call ─────────────────────────────────────────────
          Row {
            visible: tuple.loggedIn && tuple.incoming
            width: parent.width
            spacing: Style.space(8)
            ControlTile { navKey: "answer"; width: (parent.width - parent.spacing) / 2; glyph: "󰏷"; label: "Answer"; onActivated: tuple.answer() }
            ControlTile { navKey: "decline"; width: (parent.width - parent.spacing) / 2; glyph: "󰏵"; label: "Decline"; alert: true; onActivated: tuple.decline() }
          }

          // ── In call ───────────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn && tuple.inCall
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator { foreground: root.foreground }

            Repeater {
              model: tuple.peers
              PersonRow {
                required property var modelData
                width: parent.width
                name: tuple.peerName(modelData)
                caption: tuple.log.outgoing ? "Ringing…"
                  : tuple.log.peerSharing === String(modelData) ? "Sharing"
                  : (tuple.log.peerWebcam ? "Camera on" : "")
              }
            }

            // ── Their screen: open it, and choose draw or drive ──────────
            RowLayout {
              visible: tuple.log.peerSharing !== ""
              x: Style.space(6)
              width: parent.width - Style.space(6)
              spacing: Style.space(10)

              Text {
                Layout.fillWidth: true
                text: "Their screen"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                text: "Control"
                color: tuple.guestMode === "control" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              ToggleSwitch {
                property string navKey: "control"
                checked: tuple.guestMode === "control"
                hasCursor: root.hasCursor("control")
                foreground: root.foreground
                Layout.alignment: Qt.AlignVCenter
                onToggled: tuple.setGuestMode(tuple.guestMode === "control" ? "annotation" : "control")
              }

              KeyButton {
                property string navKey: "viewScreen"
                text: "View"
                tooltipText: "Bring their screen forward"
                selected: root.hasCursor("viewScreen")
                fontFamily: root.fontFamily
                onClicked: tuple.viewScreen()
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              readonly property int tiles: tuple.personalUrl !== "" ? 5 : 4
              readonly property real tileWidth: (width - spacing * (tiles - 1)) / tiles

              ControlTile {
                id: micTile
                navKey: "mute"; width: parent.tileWidth
                glyph: tuple.muted ? "󰍭" : "󰍬"
                label: tuple.muted ? "Muted" : "Mic on"
                tooltip: (tuple.muted ? "Unmute" : "Mute") + " (m) · " + (tuple.mic ? tuple.mic.label : "System default")
                split: true
                menuOpen: deviceMenu.opened && deviceMenu.kind === "mic"
                onMenuRequested: root.openDeviceMenu("mic", micTile)
                checked: tuple.muted
                busy: tuple.isPending("mute") || tuple.isPending("unmute")
                onActivated: tuple.toggleMute()
              }
              ControlTile {
                navKey: "share"; width: parent.tileWidth
                glyph: "󱒃"
                label: tuple.sharing ? "Sharing" : "Share"
                tooltip: (tuple.sharing ? "Stop sharing" : "Share your screen") + " (s)"
                checked: tuple.sharing
                busy: tuple.isPending("share") || tuple.isPending("unshare")
                onActivated: tuple.toggleShare()
              }
              ControlTile {
                id: cameraTile
                navKey: "camera"; width: parent.tileWidth
                glyph: tuple.cameraOn ? "󰖠" : "󱜷"
                label: "Camera"
                tooltip: (tuple.cameraOn ? "Hide your camera (v)" : "Show your camera on your shared screen (v) — Tuple for Linux can't send webcam video yet")
                  + (tuple.camera ? " · " + tuple.camera.name : "")
                split: tuple.cameras.length > 0
                menuOpen: deviceMenu.opened && deviceMenu.kind === "camera"
                onMenuRequested: root.openDeviceMenu("camera", cameraTile)
                checked: tuple.cameraOn
                onActivated: tuple.toggleCamera()
              }
              ControlTile {
                visible: tuple.personalUrl !== ""
                navKey: "copyLink"; width: parent.tileWidth
                glyph: "󰌹"; label: "Link"
                tooltip: "Copy call link (c)"
                onActivated: tuple.copy(tuple.personalUrl, "Call link")
              }
              ControlTile {
                navKey: "end"; width: parent.tileWidth
                glyph: "󰏵"; label: "End"; alert: true
                tooltip: "End call (e)"
                busy: tuple.isPending("end")
                onActivated: tuple.endCall()
              }
            }

            Hint {
              visible: tuple.cameraOn && !tuple.sharing
              font.pixelSize: Style.font.caption
              text: "Only you can see your camera. Tuple for Linux can't send video yet, so they'll see it when you share your screen."
            }

            DeviceMenu {
              id: deviceMenu
              property string kind: ""     // "mic" | "camera"
              heading: kind === "mic" ? "MICROPHONE" : "CAMERA"
              options: kind === "mic" ? root.micOptions : root.cameraOptions
              value: kind === "mic"
                ? (tuple.micIsDefault ? "" : tuple.micDevice)
                : (tuple.cameraIsDefault ? "" : (tuple.camera ? tuple.camera.name : ""))
              foreground: root.foreground
              mutedColor: root.dim
              hoverFill: root.hoverFill
              fontFamily: root.fontFamily
              onPicked: function(v) { if (kind === "mic") tuple.chooseMic(v); else tuple.chooseCameraName(v) }
              onClosed: root.refocusKeys()
            }
          }

          // ── Start or join: one field, one button ──────────────────────
          RowLayout {
            visible: root.showPair
            width: parent.width
            spacing: Style.space(8)
            property string navKey: "pair"

            WellField {
              id: pairField
              Layout.fillWidth: true
              foreground: root.foreground
              hasCursor: root.hasCursor("pair")
              placeholderText: "Paste a call link to join"
              text: root.joinText
              onTextChanged: root.joinText = text
              onAccepted: { root.pair(); root.refocusKeys() }
              Keys.onEscapePressed: { if (text !== "") root.joinText = ""; else root.refocusKeys() }
            }

            KeyButton {
              id: pairButton
              // With a link in the field, Join is the one thing to do: the orange key.
              primary: root.joinable && !working
              readonly property bool working: tuple.isPending("new") || tuple.isPending("join")
              text: tuple.isPending("join") ? "Joining…" : (tuple.isPending("new") ? "Starting…" : (root.joinable ? "Join" : "New call"))
              tooltipText: root.joinable ? "Join this call" : "Start a call and copy its link (n)"
              selected: root.hasCursor("pair")
              fontFamily: root.fontFamily
              Layout.preferredHeight: pairField.height
              Layout.preferredWidth: Math.max(implicitWidth, Style.space(96))
              enabled: !working
              onClicked: root.pair()
            }
          }

          // ── People ────────────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: teamHeader.implicitHeight

              PanelSectionHeader {
                id: teamHeader
                text: "PEOPLE"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                anchors.right: parent.right
                anchors.baseline: teamHeader.baseline
                visible: tuple.contactCounts.online > 0
                text: tuple.contactCounts.online + " available"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            WellField {
              id: searchField
              // Only worth showing when the list can't show everyone.
              visible: tuple.contacts.length > Model.featuredContacts(tuple.contacts, root.contactLimit).length || root.contactQuery !== ""
              width: parent.width
              property string navKey: "search"
              foreground: root.foreground
              hasCursor: root.hasCursor("search")
              placeholderText: "Search people"
              text: root.contactQuery
              onTextChanged: { root.contactQuery = text; peopleFlick.contentY = 0 }
              onAccepted: {
                if (root.shownContacts.length > 0) { root.cursorActive = true; root.cursorKey = "contact:" + root.shownContacts[0].id }
                root.refocusKeys()
              }
              Keys.onEscapePressed: { if (text !== "") root.contactQuery = ""; else root.refocusKeys() }
              Keys.onDownPressed: { if (root.shownContacts.length > 0) { root.cursorActive = true; root.cursorKey = "contact:" + root.shownContacts[0].id }; root.refocusKeys() }
            }

          }
        }

        Flickable {
          id: peopleFlick
          visible: tuple.loggedIn && root.shownContacts.length > 0
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.topMargin: Style.space(8)
          Layout.preferredHeight: contentHeight
          Layout.maximumHeight: contentHeight
          Layout.minimumHeight: Math.min(contentHeight, Style.space(120))
          contentWidth: width
          contentHeight: peopleColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          // Qt's own wheel handling is velocity-smoothed and feels sticky;
          // PeopleScroller below maps wheel and touchpad input directly.
          interactive: false
          flickDeceleration: Style.space(2500)
          maximumFlickVelocity: Style.space(6000)
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: peopleColumn
            width: peopleFlick.width
            spacing: Style.space(6)
            // Scrolled to the end, the last row clears the panel edge.
            bottomPadding: root.peopleBleed ? panel.padding : 0

            Repeater {
              model: root.shownContacts
              ContactRow {
                required property var modelData
                width: parent.width
                contact: modelData
              }
            }
          }

          PeopleScroller { flick: peopleFlick }
        }

        Column {
          id: bottomColumn
          visible: !root.peopleBleed
          Layout.fillWidth: true
          Layout.topMargin: Style.space(peopleFlick.visible ? 12 : 8)
          Layout.preferredHeight: implicitHeight
          Layout.minimumHeight: implicitHeight
          Layout.maximumHeight: implicitHeight
          spacing: Style.space(12)
          // Room for the last row's keys to stand on their lips.
          bottomPadding: depthTheme.on ? Style.space(3) : 0

          Column {
            visible: root.peopleHints
            width: parent.width
            spacing: Style.space(6)

            Hint {
              visible: root.shownContacts.length === 0
              horizontalAlignment: Text.AlignHCenter
              topPadding: Style.space(6)
              bottomPadding: Style.space(6)
              text: !tuple.contactsLoaded ? "Loading people…"
                : (tuple.contacts.length === 0 ? "No one here yet."
                : (root.contactQuery !== "" ? "No one matches “" + root.contactQuery + "”."
                : "No one's available. Search for someone and star them to call them from here."))
            }

            Hint {
              visible: root.contactQuery !== "" && root.shownContacts.length >= root.contactLimit
              horizontalAlignment: Text.AlignHCenter
              font.pixelSize: Style.font.caption
              text: "Keep typing to narrow it down."
            }
          }

        }
      }
    }
  }

  // ── Components ──────────────────────────────────────────────────────────

  // Wheel and touchpad scrolling for the people list.
  //  * Touchpads (pixelDelta) move the list 1:1 with your fingers, and keep
  //    gliding when you lift them (Wayland sends a zero-delta "scroll end").
  //  * Mouse wheels move about two rows per notch, eased over a short glide.
  component PeopleScroller: WheelHandler {
    id: scroller
    required property Flickable flick
    property real velocity: 0        // px/s, same sign as pixelDelta
    property real lastAt: 0
    readonly property real notch: Style.space(80)

    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

    function maxY() { return Math.max(0, flick.contentHeight - flick.height) }
    function clampY(y) { return Math.max(0, Math.min(maxY(), y)) }

    onWheel: function(event) {
      event.accepted = true
      if (maxY() <= 0) return
      var now = Date.now()
      var px = event.pixelDelta.y
      var ang = event.angleDelta.y

      if (px === 0 && ang === 0) {
        // Fingers lifted: carry on with the speed they had.
        if (now - lastAt < 80 && Math.abs(velocity) > Style.space(150)) flick.flick(0, velocity)
        velocity = 0
        return
      }

      flick.cancelFlick()
      if (px !== 0) {
        glide.stop()
        var dt = Math.max(1, now - lastAt)
        var v = px * 1000 / dt
        velocity = now - lastAt > 100 ? v : velocity * 0.4 + v * 0.6
        lastAt = now
        flick.contentY = clampY(flick.contentY - px)
        return
      }

      // Notched wheel: stack quick notches onto the glide's target.
      var from = glide.running ? glide.to : flick.contentY
      glide.stop()
      glide.from = flick.contentY
      glide.to = clampY(from - ang / 120 * notch)
      glide.start()
    }

    property NumberAnimation glide: NumberAnimation {
      target: scroller.flick
      property: "contentY"
      duration: 140
      easing.type: Easing.OutCubic
    }
  }

  component Hint: Text {
    width: parent ? parent.width : implicitWidth
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  // A bordered button; with depth on, a key. `primary` makes it the orange one.
  component KeyButton: Button {
    id: kb
    property bool primary: false
    readonly property bool keyed: depthTheme.on
    bordered: !keyed
    foreground: keyed && primary ? Color.popups.background : root.foreground
    Binding on color { when: kb.keyed; value: "transparent" }
    Binding on borderSpec { when: kb.keyed; value: Border.none() }
    transform: Translate { y: kbFace.sink; Behavior on y { NumberAnimation { duration: 70; easing.type: Easing.OutCubic } } }

    KeyFace {
      id: kbFace
      z: -1
      anchors.fill: parent
      visible: kb.keyed
      material: depthTheme
      face: kb.primary ? Color.accent : depthTheme.key
      hot: kb.hot || kb.selected
      pressed: kbPress.active
    }

    PointHandler { id: kbPress; enabled: kb.keyed }
  }

  // A text field; with depth on, a well set into the panel rather than a
  // frame that rises under the pointer like a key.
  component WellField: TextField {
    id: wf
    readonly property bool welled: depthTheme.on
    readonly property real edge: Math.max(1, Style.spacing.hairline)

    Binding on background { when: wf.welled; value: wfWell }
    Binding on topPadding { when: wf.welled; value: wf.verticalPadding + wf.edge }
    Binding on bottomPadding { when: wf.welled; value: wf.verticalPadding + wf.edge }
    Binding on leftPadding { when: wf.welled; value: wf.horizontalPadding + wf.edge }
    Binding on rightPadding { when: wf.welled; value: wf.horizontalPadding + wf.edge }

    WellFace {
      id: wfWell
      visible: wf.welled
      material: depthTheme
      focused: wf.activeFocus
      hot: wf.hovered || wf.hasCursor
    }
  }

  component ActionRow: CursorSurface {
    id: actionRow
    signal activated()
    signal trailingClicked()
    property string navKey: ""
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property string trailingGlyph: ""
    property bool spinning: false

    width: parent ? parent.width : implicitWidth
    hasCursor: root.hasCursor(navKey)
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: actionInner.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.hover(actionRow.navKey)
      onClicked: actionRow.activated()
    }

    RowLayout {
      id: actionInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        text: actionRow.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        Layout.alignment: Qt.AlignVCenter

        NumberAnimation on rotation {
          running: actionRow.spinning
          from: 0; to: 360; duration: 900
          loops: Animation.Infinite
        }
        onRotationChanged: if (!actionRow.spinning && rotation !== 0) rotation = 0
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: actionRow.subtitle !== ""
          Layout.fillWidth: true
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: actionRow.trailingGlyph !== ""
        iconText: actionRow.trailingGlyph
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onClicked: actionRow.trailingClicked()
      }
    }
  }

  component ControlTile: CursorSurface {
    id: tile
    signal activated()
    property string navKey: ""
    property string glyph: ""
    property string label: ""
    property string tooltip: ""
    property bool checked: false
    property bool alert: false
    property bool busy: false
    // Split tile: the main face toggles; the narrow strip on the right opens
    // a device menu (menuRequested).
    property bool split: false
    property bool menuOpen: false
    signal menuRequested()
    readonly property real splitWidth: split ? Style.space(18) : 0
    readonly property color tint: alert ? root.urgent : (checked ? root.foreground : root.foreground)

    hasCursor: root.hasCursor(navKey)
    current: checked
    bordered: true
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: Style.space(54)

    // With depth on, each tile is a key; on (muted, sharing, camera) it
    // latches down, like the switches on a Braun radio.
    readonly property bool keyed: depthTheme.on
    Binding on color { when: tile.keyed; value: "transparent" }
    Binding on borderSpec { when: tile.keyed; value: Border.none() }
    transform: Translate { y: tileFace.sink; Behavior on y { NumberAnimation { duration: 70; easing.type: Easing.OutCubic } } }

    KeyFace {
      id: tileFace
      z: -1
      anchors.fill: parent
      visible: tile.keyed
      material: depthTheme
      hot: tile.hasCursor
      pressed: tileMouse.pressed
      latched: tile.checked
    }

    MouseArea {
      id: tileMouse
      anchors.fill: parent
      anchors.rightMargin: tile.splitWidth
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.hover(tile.navKey)
      onClicked: tile.activated()
    }

    // The split: a hairline and a caret. Hovering it lights it on its own.
    Item {
      id: splitStrip
      visible: tile.split
      width: tile.splitWidth
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.right: parent.right

      Rectangle {
        width: 1
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottomMargin: Style.space(12)
        color: root.foreground
        opacity: splitMouse.containsMouse || tile.menuOpen ? 0.35 : 0.15
      }

      Text {
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: Style.space(1)
        text: "󰅀"
        rotation: tile.menuOpen ? 180 : 0
        Behavior on rotation { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        color: splitMouse.containsMouse || tile.menuOpen ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        id: splitMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.hover(tile.navKey)
        onClicked: tile.menuRequested()
      }
    }

    Column {
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: -tile.splitWidth / 2
      spacing: Style.space(4)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.glyph
        color: tile.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.iconLarge
        opacity: tile.busy ? 0.45 : 1.0
        SequentialAnimation on opacity {
          running: tile.busy
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 380 }
          NumberAnimation { to: 0.45; duration: 380 }
        }
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: tile.label
        color: tile.alert ? root.urgent : (tile.checked || tile.hasCursor ? root.foreground : root.dim)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    PanelToolTip {
      visible: tile.tooltip !== "" && tileMouse.containsMouse && !tile.menuOpen
      text: tile.tooltip
      fontFamily: root.fontFamily
    }
  }

  component Avatar: Rectangle {
    id: avatar
    property string name: ""
    width: Style.space(24)
    height: width
    radius: Style.cornerRadius > 0 ? width / 2 : 0
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)

    Text {
      anchors.centerIn: parent
      text: Model.initials(avatar.name)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component PersonRow: Item {
    id: personRow
    property string name: ""
    property string caption: ""
    implicitHeight: Style.space(30)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      Avatar { name: personRow.name; Layout.alignment: Qt.AlignVCenter }

      Text {
        Layout.fillWidth: true
        text: personRow.name
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        visible: personRow.caption !== ""
        text: personRow.caption
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  component ContactRow: CursorSurface {
    id: contactRow
    property var contact: null
    readonly property string navKey: contact ? "contact:" + contact.id : ""
    // Tuple for Linux can only ring favourites; calling someone else stars
    // them first (Service.callContact).
    readonly property bool callable: contact && contact.online && !tuple.inCall && !tuple.incoming
    readonly property bool revealed: hasCursor || rowMouse.containsMouse
    readonly property string presence: contact ? Model.presenceLabel(contact.status) : ""

    hasCursor: root.hasCursor(navKey)
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: Style.space(34)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      // A click on the row only rings favourites; anyone else takes the
      // explicit call button (which stars them first).
      cursorShape: contactRow.callable && contactRow.contact.favorite ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.hover(contactRow.navKey)
      onClicked: if (contactRow.callable && contactRow.contact.favorite) tuple.callContact(contactRow.contact)
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(10)

      // Unavailable people are faded rather than labelled.
      Avatar {
        name: contactRow.contact ? contactRow.contact.name : ""
        opacity: contactRow.contact && contactRow.contact.online ? 1 : 0.45
        Layout.alignment: Qt.AlignVCenter
      }

      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: contactRow.contact ? contactRow.contact.name : ""
        color: root.foreground
        opacity: contactRow.contact && contactRow.contact.online ? 1 : 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      // At rest: what's worth knowing. On hover: what you can do.
      Text {
        visible: !contactRow.revealed && (contactRow.presence !== "" || (contactRow.contact && contactRow.contact.favorite && root.contactQuery !== ""))
        text: contactRow.presence + (contactRow.contact && contactRow.contact.favorite && root.contactQuery !== "" ? (contactRow.presence !== "" ? "  ★" : "★") : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        Layout.alignment: Qt.AlignVCenter
      }

      PanelActionButton {
        visible: contactRow.revealed
        iconText: contactRow.contact && contactRow.contact.favorite ? "󰓎" : "󰓒"
        tooltipText: contactRow.contact && contactRow.contact.favorite ? "Remove from favorites (f)" : "Add to favorites (f)"
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.hover(contactRow.navKey) }
        onClicked: tuple.toggleFavorite(contactRow.contact)
      }

      PanelActionButton {
        visible: contactRow.revealed
        iconText: "󰏲"
        tooltipText: contactRow.callable ? (contactRow.contact.favorite ? "Call" : "Call (adds them to your favorites — Tuple for Linux only calls favorites)")
          : (tuple.inCall ? "You're already in a call" : "Not available")
        enabled: contactRow.callable && !tuple.isPending("call")
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
        onHovered: function(on) { if (on) root.hover(contactRow.navKey) }
        onClicked: tuple.callContact(contactRow.contact)
      }
    }
  }

  component SettingRow: CursorSurface {
    id: settingRow
    property var setting: null
    readonly property string navKey: setting ? "setting:" + setting.name : ""
    readonly property bool isBool: setting && setting.type === "bool"

    hasCursor: root.hasCursor(navKey)
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: Math.max(settingText.implicitHeight, settingSwitch.implicitHeight) + Style.spacing.lg

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: settingRow.setting && settingRow.setting.type !== "text" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.hover(settingRow.navKey)
      onClicked: root.cycleSetting(settingRow.setting)
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(4)
      spacing: Style.space(10)

      ColumnLayout {
        id: settingText
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: settingRow.setting ? Model.settingLabel(settingRow.setting.name) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          text: settingRow.setting ? settingRow.setting.description + (settingRow.setting.type === "text" ? " — set with: tuple set " + settingRow.setting.name + " <value>" : "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ToggleSwitch {
        id: settingSwitch
        visible: settingRow.isBool
        checked: settingRow.setting ? settingRow.setting.value === "1" : false
        cursorRing: false
        foreground: root.foreground
        Layout.alignment: Qt.AlignVCenter
        onToggled: root.cycleSetting(settingRow.setting)
      }

      Text {
        visible: !settingRow.isBool
        text: settingRow.setting ? (settingRow.setting.value !== "" ? settingRow.setting.value : "—") : ""
        color: settingRow.setting && settingRow.setting.type === "choice" ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
