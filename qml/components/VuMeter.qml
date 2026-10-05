import QtQuick

Item {
    id: root
    property real level: 0
    property string label: "L"

    Text {
        id: tag
        text: root.label
        color: "#7D8AA5"
        font.pixelSize: 10
        width: 12
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
    }
    Rectangle {
        anchors.left: tag.right
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: 6
        radius: 3
        color: "#1E2638"
        Rectangle {
            width: parent.width * Math.max(0, Math.min(1, root.level))
            height: parent.height
            radius: parent.radius
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: "#3DDAFF" }
                GradientStop { position: 0.72; color: "#7B72FF" }
                GradientStop { position: 1; color: "#FF5D9E" }
            }
            Behavior on width { NumberAnimation { duration: 70 } }
        }
    }
}

