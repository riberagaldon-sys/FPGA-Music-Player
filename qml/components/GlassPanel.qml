import QtQuick

Rectangle {
    id: root
    property color panelColor: "#B3161B2D"
    property color edgeColor: "#2CFFFFFF"
    property color accentColor: "#6C63FF"
    property bool accentEdge: false

    radius: 20
    color: panelColor
    clip: true
    border.width: 1
    border.color: accentEdge ? Qt.rgba(accentColor.r, accentColor.g,
                                      accentColor.b, 0.55) : edgeColor

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 1
        height: 1
        radius: root.radius
        color: "#42FFFFFF"
    }
}
