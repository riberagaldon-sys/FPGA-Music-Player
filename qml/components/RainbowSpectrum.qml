import QtQuick

Item {
    id: root
    property var values: []
    property real barSpacing: 4
    property bool particles: true
    property bool active: true
    property bool animateChanges: true
    property bool glowEnabled: true
    property int transitionDuration: 28
    property real floor: active ? 0.008 : 0.0

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: "#26435873"
    }

    Repeater {
        model: root.values ? root.values.length : 0
        Item {
            id: cell
            required property int index
            readonly property real amount: root.active
                ? Math.max(root.floor,
                           Math.min(1.0, Number(root.values[index]) || 0))
                : 0.0
            readonly property color bandColor: Qt.hsla(
                (index / Math.max(1, root.values.length)) * 0.78,
                0.82, 0.58, 1.0)
            width: Math.max(3, (root.width - root.barSpacing
                               * (root.values.length - 1))
                              / Math.max(1, root.values.length))
            height: root.height
            x: index * (width + root.barSpacing)

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.max(3, parent.height * cell.amount)
                radius: Math.min(5, width / 2)
                color: cell.bandColor
                opacity: 0.92
                Behavior on height {
                    enabled: root.animateChanges
                    SmoothedAnimation {
                        duration: root.active ? root.transitionDuration : 70
                        velocity: -1
                    }
                }

                Rectangle {
                    visible: root.glowEnabled
                    anchors.fill: parent
                    anchors.margins: -2
                    radius: parent.radius + 2
                    color: "transparent"
                    border.width: 2
                    border.color: Qt.rgba(cell.bandColor.r,
                                          cell.bandColor.g,
                                          cell.bandColor.b, 0.20)
                    z: -1
                }
            }

            Rectangle {
                visible: root.active && root.particles && cell.amount > 0.12
                width: Math.max(2, cell.width * 0.30)
                height: width
                radius: width / 2
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.max(0, parent.height * (1.0 - cell.amount) - 8)
                color: cell.bandColor
                opacity: 0.45 + cell.amount * 0.45
                Behavior on y {
                    enabled: root.animateChanges
                    SmoothedAnimation {
                        duration: root.transitionDuration
                        velocity: -1
                    }
                }
            }
        }
    }
}
