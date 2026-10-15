import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

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

  readonly property color barIconColor: {
    if (!tuple.installed || !tuple.daemon || !tuple.loggedIn) return Qt.darker(barForeground, 1.55)
    if (tuple.incoming) return urgent
    if (tuple.inCall) return tuple.muted ? Qt.darker(urgent, 1.5) : urgent
    return barForeground
  }

  // ── Keyboard cursor ───────────────────────────────────────────────────
  property bool cursorActive: false
  property string cursorKey: "daemon"
  property bool settingsOpen: false
  property string authCode: ""
  property string joinText: ""
  property string contactQuery: ""
  readonly property int contactLimit: 40
  // Never bind a Repeater to the full directory (orgs have thousands of
  // people); show favorites + available, or the top search matches.
  readonly property var shownContacts: Model.searchContacts(tuple.contacts, contactQuery, contactLimit)

  readonly property var navKeys: {
    var keys = []
    if (tuple.installed) keys.push("daemon")
    if (!tuple.installed || !tuple.daemon) return keys
    if (!tuple.loggedIn) {
      keys.push("login")
      if (tuple.loginUrl !== "") keys.push("loginUrl")
      if (tuple.loginPending || tuple.loginUrl !== "") keys.push("auth")
      return keys
    }
    if (tuple.incoming) { keys.push("answer"); keys.push("decline") }
    if (tuple.inCall) {
      keys.push("mute"); keys.push("share")
      if (tuple.personalUrl !== "") keys.push("copyLink")
      keys.push("end")
    } else if (!tuple.incoming) {
      keys.push("new")
      if (tuple.clipboardCallUrl !== "") keys.push("joinClipboard")
      keys.push("join")
    }
    if (tuple.contacts.length > 0) keys.push("search")
    for (var i = 0; i < shownContacts.length; i++) keys.push("contact:" + shownContacts[i].id)
    keys.push("settings")
    if (settingsOpen) for (var j = 0; j < tuple.tupleSettings.length; j++) keys.push("setting:" + tuple.tupleSettings[j].name)
    keys.push("debug")
    keys.push("logout")
    return keys
  }

  function hasCursor(key) { return cursorActive && cursorKey === key }
  function hover(key) { cursorActive = true; cursorKey = key }

  function moveCursor(dx, dy) {
    if (dx !== 0 && (cursorKey === "mute" || cursorKey === "share" || cursorKey === "copyLink" || cursorKey === "end"
        || cursorKey === "answer" || cursorKey === "decline" || cursorKey === "debug" || cursorKey === "logout")) dy = dx
    if (dy === 0) return
    var i = navKeys.indexOf(cursorKey)
    if (i === -1) i = 0
    else i = Math.max(0, Math.min(navKeys.length - 1, i + dy))
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

  function activate(key) {
    if (key === "daemon") tuple.toggleDaemon()
    else if (key === "login") tuple.login()
    else if (key === "loginUrl") tuple.openUrl(tuple.loginUrl)
    else if (key === "auth") focusField(authField)
    else if (key === "answer") tuple.answer()
    else if (key === "decline") tuple.decline()
    else if (key === "mute") tuple.toggleMute()
    else if (key === "share") tuple.toggleShare()
    else if (key === "copyLink") tuple.copy(tuple.personalUrl, "Call link")
    else if (key === "end") tuple.endCall()
    else if (key === "new") tuple.newCall()
    else if (key === "joinClipboard") tuple.join(tuple.clipboardCallUrl)
    else if (key === "join") focusField(joinField)
    else if (key === "search") focusField(searchField)
    else if (key === "settings") settingsOpen = !settingsOpen
    else if (key === "debug") tuple.openDebugUi()
    else if (key === "logout") tuple.logout()
    else if (key.indexOf("contact:") === 0) tuple.callContact(contactById(key.slice(8)))
    else if (key.indexOf("setting:") === 0) cycleSetting(settingByName(key.slice(8)))
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
      var item = findNavItem(column, cursorKey)
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursorKey = navKeys.length > 1 ? navKeys[1] : "daemon"
    if (panelFlick) panelFlick.contentY = 0
    tuple.refresh()
    refocusKeys()
  }
  onNavKeysChanged: if (navKeys.indexOf(cursorKey) === -1) cursorKey = navKeys.length > 1 ? navKeys[1] : "daemon"

  Service {
    id: tuple
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { tuple.refresh(); return "ok" }
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
    function end(): string { tuple.endCall(); return "ok" }
    function demo(scenario: string): string { return tuple.setDemo(scenario) }
    function copyLink(): string { tuple.copy(tuple.personalUrl, "Call link"); return tuple.personalUrl }
    function status(): string {
      return JSON.stringify({
        installed: tuple.installed, daemon: tuple.daemon, loggedIn: tuple.loggedIn,
        call: tuple.call, peers: tuple.peers, muted: tuple.muted, sharing: tuple.sharing,
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
        else tuple.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: joinField.activeFocus || authField.activeFocus || searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activate(root.cursorKey)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var k = t.toLowerCase()
        if (k === "m" && tuple.inCall) tuple.toggleMute()
        else if (k === "s" && tuple.inCall) tuple.toggleShare()
        else if (k === "e" && (tuple.inCall || tuple.incoming)) tuple.endCall()
        else if (k === "a" && tuple.incoming) tuple.answer()
        else if (k === "n" && tuple.loggedIn && !tuple.inCall) tuple.newCall()
        else if (k === "c" && tuple.personalUrl !== "") tuple.copy(tuple.personalUrl, "Call link")
        else if (k === "i" && tuple.loggedIn && !tuple.inCall) root.focusField(joinField)
        else if (k === "f" && root.cursorKey.indexOf("contact:") === 0) tuple.toggleFavorite(root.contactById(root.cursorKey.slice(8)))
        else if (k === "/") root.focusField(searchField)
        else if (k === "o") tuple.toggleDaemon()
        else if (k === "r") tuple.refresh()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
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
              detail: tuple.log.version !== "" ? tuple.log.version.replace(/^v(\d{4})_(\d\d)_(\d\d)\.(\d+)$/, "$1.$2.$3") : ""
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
                ToggleSwitch {
                  id: powerSwitch
                  visible: tuple.installed
                  checked: tuple.daemon
                  busy: tuple.isPending("on") || tuple.isPending("off")
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) root.hover("daemon") }
                  onToggled: tuple.toggleDaemon()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: tuple.daemon ? "Stop Tuple (you won't receive calls)" : "Start Tuple to receive calls"
                    fontFamily: hero.fontFamily
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

          Hint {
            visible: !tuple.installed
            text: "The tuple CLI isn't on PATH. Install it from tuple.app/linux into ~/.local/bin."
          }

          Hint {
            visible: tuple.installed && tuple.daemonKnown && !tuple.daemon
            text: "Tuple is off. Turn it on to start calls and get called."
          }

          // ── Login ─────────────────────────────────────────────────────
          Column {
            visible: tuple.daemon && !tuple.loggedIn
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "ACCOUNT"; foreground: root.foreground; fontFamily: root.fontFamily }

            ActionRow {
              navKey: "login"
              glyph: "󰍂"
              title: tuple.loginUrl !== "" ? "Restart login" : "Log in to Tuple"
              subtitle: "Opens tuple.app in your browser"
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

              TextField {
                id: authField
                Layout.fillWidth: true
                foreground: root.foreground
                hasCursor: root.hasCursor("auth")
                placeholderText: "Paste authorization code"
                text: root.authCode
                onTextChanged: root.authCode = text
                onAccepted: { tuple.submitAuth(text); root.authCode = ""; root.refocusKeys() }
                Keys.onEscapePressed: root.refocusKeys()
              }

              Button {
                text: "Log in"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.authCode.trim() !== "" && !tuple.isPending("auth")
                onClicked: { tuple.submitAuth(root.authCode); root.authCode = "" }
              }
            }
          }

          // ── Incoming call ─────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn && tuple.incoming
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "INCOMING CALL"; foreground: root.foreground; fontFamily: root.fontFamily }

            Row {
              width: parent.width
              spacing: Style.space(8)
              ControlTile { navKey: "answer"; width: (parent.width - parent.spacing) / 2; glyph: "󰏷"; label: "Answer"; hint: "a"; onActivated: tuple.answer() }
              ControlTile { navKey: "decline"; width: (parent.width - parent.spacing) / 2; glyph: "󰏵"; label: "Decline"; hint: "e"; alert: true; onActivated: tuple.decline() }
            }
          }

          // ── In call ───────────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn && tuple.inCall
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: tuple.call === "connecting" ? "CONNECTING" : "IN CALL"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: tuple.peers
              PersonRow {
                required property var modelData
                width: parent.width
                name: String(modelData)
                caption: tuple.log.peerSharing === String(modelData) ? "Sharing their screen" : "In the call"
                online: true
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              readonly property int tiles: tuple.personalUrl !== "" ? 4 : 3
              readonly property real tileWidth: (width - spacing * (tiles - 1)) / tiles

              ControlTile {
                navKey: "mute"; width: parent.tileWidth
                glyph: tuple.muted ? "󰍭" : "󰍬"
                label: tuple.muted ? "Unmute" : "Mute"
                hint: "m"
                checked: tuple.muted
                busy: tuple.isPending("mute") || tuple.isPending("unmute")
                onActivated: tuple.toggleMute()
              }
              ControlTile {
                navKey: "share"; width: parent.tileWidth
                glyph: tuple.sharing ? "󰞊" : "󱒃"
                label: tuple.sharing ? "Stop share" : "Share"
                hint: "s"
                checked: tuple.sharing
                busy: tuple.isPending("share") || tuple.isPending("unshare")
                onActivated: tuple.toggleShare()
              }
              ControlTile {
                visible: tuple.personalUrl !== ""
                navKey: "copyLink"; width: parent.tileWidth
                glyph: "󰌹"; label: "Copy link"; hint: "c"
                onActivated: tuple.copy(tuple.personalUrl, "Call link")
              }
              ControlTile {
                navKey: "end"; width: parent.tileWidth
                glyph: "󰏵"; label: "End"; hint: "e"; alert: true
                busy: tuple.isPending("end")
                onActivated: tuple.endCall()
              }
            }
          }

          // ── Start a call ──────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn && !tuple.inCall && !tuple.incoming
            width: parent.width
            spacing: Style.space(8)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "PAIR"; foreground: root.foreground; fontFamily: root.fontFamily }

            ActionRow {
              navKey: "new"
              glyph: "󰐕"
              title: "New call"
              subtitle: "Start your personal room and copy the link"
              hint: "n"
              spinning: tuple.isPending("new")
              onActivated: tuple.newCall()
            }

            ActionRow {
              visible: tuple.clipboardCallUrl !== ""
              navKey: "joinClipboard"
              glyph: "󰆒"
              title: "Join from clipboard"
              subtitle: tuple.clipboardCallUrl
              spinning: tuple.isPending("join")
              onActivated: tuple.join(tuple.clipboardCallUrl)
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(8)
              property string navKey: "join"

              TextField {
                id: joinField
                Layout.fillWidth: true
                foreground: root.foreground
                hasCursor: root.hasCursor("join")
                placeholderText: "Paste a tuple.app/c/… link  (i)"
                text: root.joinText
                onTextChanged: root.joinText = text
                onAccepted: { tuple.join(text); root.joinText = ""; root.refocusKeys() }
                Keys.onEscapePressed: root.refocusKeys()
              }

              Button {
                text: "Join"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: Model.extractCallUrl(root.joinText) !== "" && !tuple.isPending("join")
                onClicked: { tuple.join(root.joinText); root.joinText = "" }
              }
            }
          }

          // ── Contacts ──────────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: {
                var c = tuple.contactCounts
                if (c.total === 0) return "TEAM"
                return "TEAM · " + c.onlineFavorites + "/" + c.favorites + " FAVORITES ONLINE · " + c.online + " AVAILABLE"
              }
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField {
              id: searchField
              visible: tuple.contacts.length > 0
              width: parent.width
              property string navKey: "search"
              foreground: root.foreground
              hasCursor: root.hasCursor("search")
              placeholderText: "Search " + tuple.contactCounts.total.toLocaleString() + " people  (/)"
              text: root.contactQuery
              onTextChanged: root.contactQuery = text
              onAccepted: {
                if (root.shownContacts.length > 0) { root.cursorActive = true; root.cursorKey = "contact:" + root.shownContacts[0].id }
                root.refocusKeys()
              }
              Keys.onEscapePressed: { if (text !== "") root.contactQuery = ""; else root.refocusKeys() }
              Keys.onDownPressed: { if (root.shownContacts.length > 0) { root.cursorActive = true; root.cursorKey = "contact:" + root.shownContacts[0].id }; root.refocusKeys() }
            }

            Text {
              visible: root.shownContacts.length === 0
              width: parent.width
              text: !tuple.contactsLoaded ? "Loading contacts…"
                : (tuple.contacts.length === 0 ? "No contacts yet."
                : (root.contactQuery !== "" ? "Nobody matches “" + root.contactQuery + "”." : "No favorites or available teammates. Search to find someone, then ★ them."))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.shownContacts
              ContactRow {
                required property var modelData
                width: parent.width
                contact: modelData
              }
            }

            Text {
              visible: root.contactQuery !== "" && root.shownContacts.length >= root.contactLimit
              width: parent.width
              text: "Showing the first " + root.contactLimit + " matches — keep typing to narrow it down."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ── Settings ──────────────────────────────────────────────────
          Column {
            visible: tuple.loggedIn && tuple.tupleSettings.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSeparator { foreground: root.foreground }

            ActionRow {
              navKey: "settings"
              glyph: "󰒓"
              title: "Settings"
              subtitle: root.settingsOpen ? "" : tuple.tupleSettings.length + " options"
              trailingText: root.settingsOpen ? "−" : "+"
              onActivated: root.settingsOpen = !root.settingsOpen
            }

            Repeater {
              model: root.settingsOpen ? tuple.tupleSettings : []
              SettingRow {
                required property var modelData
                width: parent.width
                setting: modelData
              }
            }
          }

          // ── Footer ────────────────────────────────────────────────────
          Row {
            visible: tuple.loggedIn
            width: parent.width
            spacing: Style.space(8)
            ControlTile { navKey: "debug"; width: (parent.width - parent.spacing) / 2; glyph: "󰏌"; label: "Tuple window"; compact: true; onActivated: tuple.openDebugUi() }
            ControlTile { navKey: "logout"; width: (parent.width - parent.spacing) / 2; glyph: "󰍃"; label: "Log out"; compact: true; onActivated: tuple.logout() }
          }
        }
      }
    }
  }

  // ── Components ──────────────────────────────────────────────────────────

  component Hint: Text {
    width: parent ? parent.width : implicitWidth
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    wrapMode: Text.WordWrap
  }

  component ActionRow: CursorSurface {
    id: actionRow
    signal activated()
    signal trailingClicked()
    property string navKey: ""
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property string hint: ""
    property string trailingText: ""
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

      Text {
        visible: actionRow.hint !== "" || actionRow.trailingText !== ""
        text: actionRow.trailingText !== "" ? actionRow.trailingText : actionRow.hint
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: actionRow.trailingText !== "" ? Style.font.heading : Style.font.caption
        Layout.alignment: Qt.AlignVCenter
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
    property string hint: ""
    property bool checked: false
    property bool alert: false
    property bool busy: false
    property bool compact: false
    readonly property color tint: alert ? root.urgent : root.foreground

    hasCursor: root.hasCursor(navKey)
    current: checked
    bordered: true
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: compact ? Style.space(34) : Style.space(58)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.hover(tile.navKey)
      onClicked: tile.activated()
    }

    Column {
      visible: !tile.compact
      anchors.centerIn: parent
      spacing: Style.space(3)

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
        color: tile.alert ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      visible: tile.compact
      anchors.centerIn: parent
      spacing: Style.space(8)
      Text { text: tile.glyph; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.icon; anchors.verticalCenter: parent.verticalCenter }
      Text { text: tile.label; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; anchors.verticalCenter: parent.verticalCenter }
    }

    Text {
      visible: tile.hint !== "" && !tile.compact
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.margins: Style.space(5)
      text: tile.hint
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Avatar: Rectangle {
    id: avatar
    property string name: ""
    property bool online: false
    property bool showPresence: true
    width: Style.space(26)
    height: width
    radius: Style.cornerRadius > 0 ? width / 2 : 0
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, online ? 0.16 : 0.07)

    Text {
      anchors.centerIn: parent
      text: Model.initials(avatar.name)
      color: avatar.online ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Rectangle {
      visible: avatar.showPresence
      width: Style.space(8)
      height: width
      radius: width / 2
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: -Style.space(1)
      color: avatar.online ? Color.accent : Color.background
      border.width: Math.max(1, Style.space(1))
      border.color: avatar.online ? Color.background : root.dim
    }
  }

  component PersonRow: Item {
    id: personRow
    property string name: ""
    property string caption: ""
    property bool online: false
    implicitHeight: Style.space(34)

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Avatar { name: personRow.name; online: personRow.online; anchors.verticalCenter: parent.verticalCenter }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        Text { text: personRow.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
        Text { text: personRow.caption; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
      }
    }
  }

  component ContactRow: CursorSurface {
    id: contactRow
    property var contact: null
    readonly property string navKey: contact ? "contact:" + contact.id : ""
    readonly property bool callable: contact && contact.favorite && contact.online && !tuple.inCall && !tuple.incoming

    hasCursor: root.hasCursor(navKey)
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: contactInner.implicitHeight + Style.spacing.lg

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: contactRow.callable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onEntered: root.hover(contactRow.navKey)
      onClicked: if (contactRow.callable) tuple.callContact(contactRow.contact)
    }

    RowLayout {
      id: contactInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(10)

      Avatar {
        name: contactRow.contact ? contactRow.contact.name : ""
        online: contactRow.contact ? contactRow.contact.online : false
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: contactRow.contact ? contactRow.contact.name : ""
          color: contactRow.contact && contactRow.contact.online ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: contactRow.contact ? [contactRow.contact.status, contactRow.contact.email].filter(function(s) { return s !== "" }).join(" · ") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        iconText: contactRow.contact && contactRow.contact.favorite ? "󰓎" : "󰓒"
        tooltipText: contactRow.contact && contactRow.contact.favorite ? "Unfavorite (f)" : "Favorite (f) — only favorites can be called"
        foreground: contactRow.contact && contactRow.contact.favorite ? root.foreground : root.dim
        fontFamily: root.fontFamily
        hasCursor: false
        Layout.alignment: Qt.AlignVCenter
        onClicked: tuple.toggleFavorite(contactRow.contact)
      }

      PanelActionButton {
        iconText: "󰏲"
        tooltipText: contactRow.callable ? "Call" : (tuple.inCall ? "Already in a call" : "Online favorites can be called")
        enabled: contactRow.callable && !tuple.isPending("call")
        foreground: root.foreground
        fontFamily: root.fontFamily
        Layout.alignment: Qt.AlignVCenter
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
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
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
          text: settingRow.setting ? settingRow.setting.description + (settingRow.setting.type === "text" ? " — tuple set " + settingRow.setting.name + " <value>" : "") : ""
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
        text: settingRow.setting ? (settingRow.setting.value !== "" ? settingRow.setting.value : "—") + (settingRow.setting.type === "choice" ? "  ›" : "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
