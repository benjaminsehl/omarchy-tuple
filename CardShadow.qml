import QtQuick
import QtQuick.Effects
import qs.Commons

// The panel card's shadow. Put it first inside a KeyboardPanel: the panel
// draws its card on a full-screen surface, so there is room around it, and
// this moves onto that surface, just behind the card, and fades with it.
// Off unless the theme sets material.shadow-alpha. If KeyboardPanel's
// layout ever changes, it finds no card and draws nothing.
Item {
  id: cs

  required property Material material
  property Item card: null

  visible: !!card && material.shadowAlpha > 0
  x: card ? card.x : 0
  y: card ? card.y : 0
  width: card ? card.width : 0
  height: card ? card.height : 0
  opacity: card ? card.opacity : 0

  Component.onCompleted: {
    var c = parent ? parent.parent : null  // content holder -> card
    if (!c || !c.parent || c.radius === undefined) return
    card = c
    parent = c.parent
    c.z = Math.max(c.z, 1)
    z = c.z - 0.5
  }

  // Ambient: soft and offset down, as if the card hangs a little off the wall.
  RectangularShadow {
    anchors.fill: parent
    offset.y: Style.space(10)
    blur: Style.space(28)
    spread: -Style.space(6)
    radius: cs.card ? cs.card.radius : 0
    color: Util.alpha(cs.material.shadow, cs.material.shadowAlpha)
  }

  // Contact: tight, where the card meets the surface.
  RectangularShadow {
    anchors.fill: parent
    offset.y: Style.space(1)
    blur: Style.space(3)
    radius: cs.card ? cs.card.radius : 0
    color: Util.alpha(cs.material.shadow, cs.material.shadowAlpha * 0.7)
  }
}
