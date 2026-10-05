import QtQuick

Item {
    id: root
    property var values: []
    property color lowColor: "#4FD1FF"
    property color highColor: "#9C6CFF"
    property real spacing: 4

    Repeater {
        model: root.values ? root.values.length : 0
        Rectangle {
            required property int index
            readonly property real amount: Math.max(0.025,
                Math.min(1.0, Number(root.values[index])))
            width: Math.max(2, (root.width - root.spacing * (root.values.length - 1))
                            / root.values.length)
            height: Math.max(3, root.height * amount)
            x: index * (width + root.spacing)
            anchors.bottom: parent.bottom
            radius: Math.min(width / 2, 4)
            opacity: 0.5 + amount * 0.5
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.highColor }
                GradientStop { position: 0.55; color: "#5B8CFF" }
                GradientStop { position: 1.0; color: root.lowColor }
            }
            Behavior on height {
                NumberAnimation { duration: 55; easing.type: Easing.OutCubic }
            }
        }
    }
}

