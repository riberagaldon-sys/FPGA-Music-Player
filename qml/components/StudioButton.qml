import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Button {
    id: root
    property bool primary: false
    property bool danger: false
    property string symbol: ""
    property int symbolPixelSize: 15
    property int minimumButtonWidth: 116

    implicitWidth: Math.max(minimumButtonWidth,
                            buttonContent.implicitWidth + leftPadding + rightPadding)
    implicitHeight: 46
    Layout.minimumWidth: minimumButtonWidth
    Layout.minimumHeight: 42
    clip: true
    leftPadding: 14
    rightPadding: 14
    hoverEnabled: true
    font.pixelSize: 13
    font.weight: Font.DemiBold

    background: Rectangle {
        radius: 12
        color: root.danger
               ? (root.down ? "#D94A67" : "#EF5B76")
               : root.primary
                 ? (root.down ? "#5C51E7" : root.hovered ? "#786EFF" : "#6C63F5")
                 : (root.hovered ? "#202A42" : "#141C2D")
        border.width: root.primary || root.danger ? 0 : 1
        border.color: "#2A3651"
        opacity: root.enabled ? 1.0 : 0.45
    }

    contentItem: Item {
        implicitWidth: root.text.length === 0 ? iconOnly.implicitWidth : buttonContent.implicitWidth
        implicitHeight: root.text.length === 0 ? iconOnly.implicitHeight : buttonContent.implicitHeight

        // Icon-only media buttons use the whole content box. This prevents two-character
        // previous/next symbols from looking shifted to one side.
        Text {
            id: iconOnly
            visible: root.text.length === 0 && root.symbol.length > 0
            anchors.fill: parent
            text: root.symbol
            color: "#F7F8FF"
            font.pixelSize: root.symbolPixelSize
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }

        Row {
            id: buttonContent
            visible: root.text.length > 0
            spacing: root.symbol.length > 0 ? 8 : 0
            anchors.centerIn: parent
            Text {
                visible: root.symbol.length > 0
                text: root.symbol
                color: "#F7F8FF"
                font.pixelSize: root.symbolPixelSize
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: root.text
                color: "#F7F8FF"
                font: root.font
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
