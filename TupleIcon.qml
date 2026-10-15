import QtQuick

// Tuple's mark — two offset rounded squares — drawn natively so it follows
// the Omarchy theme colours instead of shipping the purple PNG.
//
// badge: "" | "muted" | "sharing" | "incoming"
Item {
  id: root

  property real iconSize: 14
  property color color: "white"
  property color badgeColor: "red"
  property string badge: ""
  property bool crossed: false
  property bool pulsing: false

  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real tile: iconSize * 0.70
  readonly property real offset: iconSize - tile

  Item {
    id: mark
    anchors.fill: parent
    opacity: root.crossed ? 0.55 : 1.0

    // Back tile (lower-right), lighter.
    Rectangle {
      x: root.offset
      y: root.offset
      width: root.tile
      height: root.tile
      radius: root.tile * 0.16
      color: root.color
      opacity: 0.45
    }

    // Front tile (upper-left), solid.
    Rectangle {
      x: 0
      y: 0
      width: root.tile
      height: root.tile
      radius: root.tile * 0.16
      color: root.color
    }

    SequentialAnimation on opacity {
      running: root.pulsing
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 520; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 520; easing.type: Easing.InOutQuad }
      onRunningChanged: if (!running) mark.opacity = root.crossed ? 0.55 : 1.0
    }
  }

  // Diagonal slash when the daemon is off.
  Rectangle {
    visible: root.crossed
    anchors.centerIn: parent
    width: Math.max(1.5, root.iconSize * 0.12)
    height: root.iconSize * 1.25
    rotation: -45
    color: root.color
    antialiasing: true
  }

  // Status badge in the bottom-right corner.
  Rectangle {
    visible: root.badge !== ""
    width: Math.max(4, root.iconSize * 0.42)
    height: width
    radius: width / 2
    x: root.iconSize - width * 0.65
    y: root.iconSize - width * 0.65
    color: root.badgeColor
    border.width: Math.max(1, root.iconSize * 0.07)
    border.color: "transparent"
  }
}
