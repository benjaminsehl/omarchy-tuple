import QtQuick
import qs.Commons

// A field set into the body, the opposite of a key: lit from above, its top
// edge falls into shade and its bottom edge catches the light. Use it as a
// TextField's background. Keyboard focus rings it in the accent, as
// everywhere else. At depth 0 it's a plain hairline frame.
Item {
  id: well

  required property Material material
  property bool focused: false
  property bool hot: false
  property color body: Color.popups.background
  property color accent: Color.accent

  readonly property real d: material.depth
  readonly property real r: Style.cornerRadius
  readonly property real edge: Math.max(1, Style.spacing.hairline)
  // A dark body catches far less light, and needs more shade to show it.
  readonly property bool darkBody: body.hslLightness < 0.5

  // The body's lit edge just under the well's lower lip.
  Rectangle {
    anchors.fill: parent
    anchors.topMargin: well.edge
    anchors.bottomMargin: -well.edge
    radius: well.r
    color: Qt.tint(well.body, Qt.rgba(1, 1, 1, (well.darkBody ? 0.08 : 0.65) * well.d))
  }

  Rectangle {
    anchors.fill: parent
    radius: well.r
    color: Qt.tint(well.body, Qt.rgba(0, 0, 0, (well.darkBody ? 0.25 : 0.035) * well.d))
    border.width: well.edge
    border.color: well.focused ? well.accent
      : (well.darkBody ? Qt.tint(well.body, Qt.rgba(1, 1, 1, well.hot ? 0.16 : 0.10))
         : Qt.tint(well.body, Qt.rgba(0, 0, 0, (well.hot ? 0.30 : 0.22) * Math.max(well.d, 0.6))))

    // Shade falling in from the top edge.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: well.edge
      height: Math.min(parent.height / 2, Style.space(8))
      radius: Math.max(0, well.r - well.edge)
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, (well.darkBody ? 0.35 : 0.09) * well.d) }
        GradientStop { position: 1; color: "transparent" }
      }
    }
  }
}
