import QtQuick
import QtQuick.Controls

Button {
    id: root
    property string iconText: ""
    property bool selected: false

    implicitWidth: 174
    implicitHeight: 52
    hoverEnabled: true
    padding: 0

    background: Rectangle {
        radius: 14
        color: root.selected ? "#256C63FF"
                             : (root.hovered ? "#13FFFFFF" : "transparent")
        border.width: root.selected ? 1 : 0
        border.color: "#546C63FF"

        Rectangle {
            visible: root.selected
            width: 3
            height: 24
            radius: 2
            anchors.left: parent.left
            anchors.leftMargin: 1
            anchors.verticalCenter: parent.verticalCenter
            color: "#7D72FF"
        }
    }

    contentItem: Item {
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 14
            Text {
                text: root.iconText
                width: 24
                color: root.selected ? "#A9A3FF" : "#8290AA"
                font.pixelSize: 19
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.text
                color: root.selected ? "#F5F6FF" : "#97A2B8"
                font.pixelSize: 14
                font.weight: root.selected ? Font.DemiBold : Font.Medium
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
