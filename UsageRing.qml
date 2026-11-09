// Adapted from DankClaudeUsage, Copyright (c) 2026 Bogdan Velicu, MIT License:
// https://github.com/bogdan-velicu/DankClaudeUsage (full notice in THIRD_PARTY_NOTICES.md)
// A small circular progress gauge. The percentage is shown beside it (by the
// caller), not inside — it's unreadable at bar size.
import QtQuick
import qs.Common

Item {
    id: root
    property int percentage: 0          // 0..100
    property color ringColor: Theme.primary
    property real diameter: Theme.iconSizeSmall
    property real thickness: Math.max(Theme.outlineWidthFocused, diameter / 6.4)

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
            function onDiameterChanged() { canvas.requestPaint() }
        }
    }
}
