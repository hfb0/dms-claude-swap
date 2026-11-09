// The plugin's own mark: a spark inside two circling arrows ("the account rotates
// on its own"). Lit (accent color) while auto switch is on, muted while it is off.
// Drawn on a 24×24 grid and scaled to `size`.
import QtQuick
import qs.Common

Item {
    id: root
    property real size: Theme.iconSize
    property bool lit: false
    property color litColor: Theme.primary
    property color mutedColor: Theme.widgetIconColor
    property real mutedOpacity: 0.4

    implicitWidth: size
    implicitHeight: size
    opacity: lit ? 1 : mutedOpacity
    Behavior on opacity { NumberAnimation { duration: Theme.shortDuration } }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const color = root.lit ? root.litColor : root.mutedColor
            ctx.scale(width / 24, height / 24)
            ctx.strokeStyle = color
            ctx.fillStyle = color
            ctx.lineWidth = 2.1
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            // One arrow: an arc over the top of a radius-8 circle, head on the left.
            function arrow() {
                ctx.beginPath()
                ctx.arc(12, 12, 8, Math.atan2(-3.8, 7.2), Math.atan2(-4.4, -6.8), true)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(2.9, 5.2)
                ctx.lineTo(5.2, 7.9)
                ctx.lineTo(8.4, 6.6)
                ctx.stroke()
            }
            arrow()
            ctx.save()
            ctx.translate(12, 12)
            ctx.rotate(Math.PI)
            ctx.translate(-12, -12)
            arrow()
            ctx.restore()

            // Four-point spark in the middle. The control points sit slightly off-center so
            // the sides stay concave but the body keeps enough mass to read at bar size.
            const r = 4.8, k = 1.3
            ctx.beginPath()
            ctx.moveTo(12, 12 - r)
            ctx.quadraticCurveTo(12 + k, 12 - k, 12 + r, 12)
            ctx.quadraticCurveTo(12 + k, 12 + k, 12, 12 + r)
            ctx.quadraticCurveTo(12 - k, 12 + k, 12 - r, 12)
            ctx.quadraticCurveTo(12 - k, 12 - k, 12, 12 - r)
            ctx.closePath()
            ctx.fill()
        }
        Connections {
            target: root
            function onLitChanged() { canvas.requestPaint() }
            function onLitColorChanged() { canvas.requestPaint() }
            function onMutedColorChanged() { canvas.requestPaint() }
            function onSizeChanged() { canvas.requestPaint() }
        }
    }
}
