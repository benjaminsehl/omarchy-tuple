import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// Device picker for the Mic and Camera split tiles: a popup under the tile
// with "System default" (naming what that currently is), then each device.
// The current choice carries a check. j/k or arrows move, enter picks, esc
// closes. Options are [{ value, label, detail }]; value "" is the default.
Popup {
  id: menu

  property string heading: ""
  property var options: []
  property string value: ""
  property Item anchorTile: null
  property color foreground: Color.foreground
  property color mutedColor: Qt.darker(foreground, 1.55)
  property color hoverFill: "transparent"
  property string fontFamily: Style.font.family
  readonly property int rowHeight: Style.space(34)
  readonly property var borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

  signal picked(string value)

  width: Math.min(parent ? parent.width : Style.space(280), Style.space(280))
  x: {
    if (!anchorTile || !parent) return 0
    var p = anchorTile.mapToItem(parent, 0, 0)
    return Math.max(0, Math.min(parent.width - width, p.x))
  }
  y: (!anchorTile || !parent) ? 0 : anchorTile.mapToItem(parent, 0, anchorTile.height).y + Style.space(6)
  padding: Style.space(4)
  focus: true
  closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

  background: BorderSurface {
    color: Color.popups.background
    borderSpec: menu.borderSpec
    radius: Style.cornerRadius
  }

  onOpened: {
    var i = 0
    for (var k = 0; k < options.length; k++) if (options[k].value === value) i = k
    list.currentIndex = i
    list.forceActiveFocus()
  }

  function pick(index) {
    if (index < 0 || index >= options.length) return
    picked(options[index].value)
    close()
  }

  contentItem: Column {
    spacing: Style.space(2)

    Text {
      visible: menu.heading !== ""
      leftPadding: Style.space(10)
      topPadding: Style.space(4)
      bottomPadding: Style.space(4)
      text: menu.heading
      color: menu.mutedColor
      font.family: menu.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    ListView {
      id: list
      width: parent.width
      height: contentHeight
      interactive: false
      model: menu.options
      spacing: Style.space(2)

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { menu.close(); event.accepted = true }
        else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || event.text === "j") { list.currentIndex = Math.min(menu.options.length - 1, list.currentIndex + 1); event.accepted = true }
        else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || event.text === "k") { list.currentIndex = Math.max(0, list.currentIndex - 1); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) { menu.pick(list.currentIndex); event.accepted = true }
      }

      delegate: Rectangle {
        id: optionRow
        required property var modelData
        required property int index
        readonly property bool hot: index === list.currentIndex
        readonly property bool chosen: modelData.value === menu.value
        readonly property bool hasDetail: String(modelData.detail || "") !== ""
        width: list.width
        height: menu.rowHeight
        radius: Style.cornerRadius
        color: hot ? menu.hoverFill : "transparent"

        // A hairline under "System default" sets it apart from the devices.
        Rectangle {
          visible: optionRow.index === 0 && menu.options.length > 1
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.bottom
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          height: 1
          color: menu.foreground
          opacity: 0.12
        }

        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(8)

          Text {
            text: optionRow.modelData.label
            color: menu.foreground
            font.family: menu.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
            Layout.fillWidth: !optionRow.hasDetail
          }

          Text {
            visible: optionRow.hasDetail
            text: String(optionRow.modelData.detail || "")
            color: menu.mutedColor
            font.family: menu.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            Layout.fillWidth: true
          }

          Text {
            text: "󰄬"
            opacity: optionRow.chosen ? 1 : 0
            color: menu.foreground
            font.family: menu.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: list.currentIndex = optionRow.index
          onClicked: menu.pick(optionRow.index)
        }
      }
    }
  }
}
