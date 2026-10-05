import QtQuick

Canvas {
    id: canvas
    property var values: []
    property color lineColor: "#66D7FF"
    property bool active: true
    property real strokeWidth: 2
    property real glowRadius: 8
    antialiasing: true
    renderStrategy: Canvas.Threaded

    onValuesChanged: requestPaint()
    onActiveChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        if (!active || !values || values.length < 2)
            return

        const middle = height / 2
        const gradient = ctx.createLinearGradient(0, 0, width, 0)
        gradient.addColorStop(0, "#3EC8FF")
        gradient.addColorStop(0.5, "#7D72FF")
        gradient.addColorStop(1, "#C35CFF")
        ctx.strokeStyle = gradient
        ctx.lineWidth = strokeWidth
        ctx.shadowColor = lineColor
        ctx.shadowBlur = glowRadius
        ctx.beginPath()
        for (let i = 0; i < values.length; ++i) {
            const x = i * width / (values.length - 1)
            const y = middle - Number(values[i]) * middle * 0.82
            if (i === 0)
                ctx.moveTo(x, y)
            else
                ctx.lineTo(x, y)
        }
        ctx.stroke()
    }
}
