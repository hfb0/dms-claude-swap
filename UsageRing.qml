// Adapted from DankClaudeUsage by Bogdan Velicu (MIT): https://github.com/bogdan-velicu/DankClaudeUsage
// A small circular progress gauge. The percentage is shown beside it (by the
// caller), not inside — it's unreadable at bar size.
import QtQuick
import qs.Common

Item {
    id: root
    property int percentage: 0          // 0..100
    property color ringColor: Theme.primary
    property int diameter: 16
    property real thickness: 2.5

    implicitWidth: diameter
    implicitHeight: diameter

    Canvas {
        id: canvas
        renderStrategy: Canvas.Cooperative
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            const c = width / 2
            const r = (Math.min(width, height) - root.thickness) / 2
            const frac = Math.max(0, Math.min(1, root.percentage / 100))

            ctx.lineWidth = root.thickness
            ctx.strokeStyle = Theme.surfaceVariant
            ctx.beginPath()
            ctx.arc(c, c, r, 0, 2 * Math.PI)
            ctx.stroke()

            if (frac > 0) {
                ctx.strokeStyle = root.ringColor
                ctx.lineCap = "round"
                ctx.beginPath()
                ctx.arc(c, c, r, -Math.PI / 2, -Math.PI / 2 + frac * 2 * Math.PI)
                ctx.stroke()
            }
        }
        Connections {
            target: root
            function onPercentageChanged() { canvas.requestPaint() }
            function onRingColorChanged() { canvas.requestPaint() }
        }
    }
}
