import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs
import "components"

ApplicationWindow {
    id: window
    width: 1640
    height: 980
    minimumWidth: 1280
    minimumHeight: 800
    visible: true
    title: "GX Music Studio  •  FPGA Hi-Fi Control"
    color: "#080C16"

    property int pageIndex: 0
    readonly property color textPrimary: "#F4F6FF"
    readonly property color textSecondary: "#8794AD"
    readonly property color purple: "#7167F6"
    readonly property color cyan: "#3FD7FF"

    function hexByte(value) {
        const text = Math.max(0, Number(value) || 0).toString(16)
        return text.length < 2 ? "0" + text : text.slice(-2)
    }

    function activatePage(index) {
        pageIndex = index
        // “正在播放”是电脑本地播放器，“外部播放器”是 Windows
        // 其他软件；两者的声音都需要经电脑音频输出 -> 3.5 mm ->
        // 核心板 LINE_IN。进入这两个页面时只请求一次 LINE IN，
        // AppController 会避免同源重复复位。
        if ((index === 0 || index === 3) && appController.boardOnline)
            appController.boardSelectSource(2)
    }

    background: Item {
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: "#11172B" }
                GradientStop { position: 0.50; color: "#090D18" }
                GradientStop { position: 1.0; color: "#070B14" }
            }
        }
        Rectangle {
            width: 610; height: 610; radius: 305
            x: parent.width * 0.27; y: -405
            color: "#167369FF"
            scale: 1 + Math.max(appController.peakLevel,
                                appController.systemPeakLevel) * 0.08
            Behavior on scale { NumberAnimation { duration: 100 } }
        }
        Rectangle {
            width: 470; height: 470; radius: 235
            x: parent.width - 250; y: parent.height - 190
            color: "#103BD6FF"
        }
    }

    FileDialog {
        id: mp3Dialog
        title: "选择 MP3 音乐"
        nameFilters: ["MP3 音频 (*.mp3)", "全部文件 (*)"]
        onAccepted: appController.setImportMp3(selectedFile)
    }
    FileDialog {
        id: lrcDialog
        title: "选择对应的 LRC 歌词"
        nameFilters: ["LRC 歌词 (*.lrc)", "文本歌词 (*.txt)"]
        onAccepted: appController.setImportLrc(selectedFile)
    }

    Connections {
        target: appController
        function onToastMessageChanged() {
            if (appController.toastMessage.length > 0)
                toastTimer.restart()
        }
    }
    Timer {
        id: toastTimer
        interval: 5600
        onTriggered: appController.clearToast()
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 18
        spacing: 18

        GlassPanel {
            Layout.preferredWidth: 238
            Layout.minimumWidth: 218
            Layout.fillHeight: true
            panelColor: "#D10F1524"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: 24
                    Rectangle {
                        width: 48; height: 48; radius: 14
                        gradient: Gradient {
                            GradientStop { position: 0; color: "#826FFF" }
                            GradientStop { position: 1; color: "#32CFF2" }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: "GX"
                            color: "white"
                            font.pixelSize: 16
                            font.bold: true
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            text: "MUSIC STUDIO"
                            color: window.textPrimary
                            font.pixelSize: 14
                            font.bold: true
                            font.letterSpacing: 1.1
                        }
                        Text {
                            text: "FPGA Hi-Fi Console"
                            color: window.textSecondary
                            font.pixelSize: 10
                        }
                    }
                }

                NavButton { Layout.fillWidth: true; text: "正在播放"; iconText: "◉"; selected: window.pageIndex === 0; onClicked: window.activatePage(0) }
                NavButton { Layout.fillWidth: true; text: "歌曲导入"; iconText: "＋"; selected: window.pageIndex === 1; onClicked: window.activatePage(1) }
                NavButton { Layout.fillWidth: true; text: "核心板设备"; iconText: "⌁"; selected: window.pageIndex === 2; onClicked: window.activatePage(2) }
                NavButton { Layout.fillWidth: true; text: "外部播放器"; iconText: "≋"; selected: window.pageIndex === 3; onClicked: window.activatePage(3) }

                Item { Layout.fillHeight: true }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 132
                    radius: 16
                    color: appController.boardOnline ? "#13262D38" : "#1219232F"
                    border.width: 1
                    border.color: appController.boardOnline ? "#3751E6B5" : "#27324A"
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        spacing: 7
                        Row {
                            spacing: 8
                            Rectangle { width: 8; height: 8; radius: 4; color: appController.boardOnline ? "#47E6B2" : "#657187"; anchors.verticalCenter: parent.verticalCenter }
                            Text { text: appController.boardOnline ? "GX FPGA ONLINE" : "FPGA OFFLINE"; color: appController.boardOnline ? "#8EF2D0" : "#7D899F"; font.pixelSize: 11; font.bold: true }
                        }
                        Text { Layout.fillWidth: true; text: appController.serialStatus; color: window.textSecondary; font.pixelSize: 10; wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight }
                        Text { text: appController.boardSdReady ? (appController.boardSdReadyKnown ? "TF：READY" : "TF：READY（推断）") : (appController.boardSdReadyKnown ? "TF：NOT READY" : "TF：UNKNOWN"); color: appController.boardSdReady ? "#42D7FF" : "#6A758C"; font.pixelSize: 10 }
                        Text { text: "44.1 kHz  •  16-bit  •  Stereo"; color: "#5D6981"; font.pixelSize: 9 }
                    }
                }

                Text { Layout.alignment: Qt.AlignHCenter; text: "GX-BIDT  /  XC7A200T"; color: "#4C5770"; font.pixelSize: 9; font.letterSpacing: 0.8 }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 12

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 64
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text { text: ["音乐控制中心", "MP3 + LRC 歌曲制作", "FPGA 播放与设备控制", "其他播放器实时监视"][window.pageIndex]; color: window.textPrimary; font.pixelSize: 24; font.weight: Font.DemiBold }
                    Text { text: ["本地试听、滚动歌词与实时彩色频谱", "电脑读卡器直写或经 USB-UART 上传板载 TF卡", "与播放器一致的板端播放、音量、音调与传输控制", "监视网易云、QQ 音乐等 Windows 系统播放声音"][window.pageIndex]; color: window.textSecondary; font.pixelSize: 11 }
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                    implicitWidth: statusText.implicitWidth + 40
                    implicitHeight: 36
                    radius: 18
                    color: appController.boardOnline ? "#1745E6B0" : "#121B2538"
                    border.width: 1
                    border.color: appController.boardOnline ? "#3D45E6B0" : "#293650"
                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Rectangle { width: 7; height: 7; radius: 4; color: appController.boardOnline ? "#45E6B0" : "#68748A"; anchors.verticalCenter: parent.verticalCenter }
                        Text { id: statusText; text: appController.boardOnline ? "BOARD CONNECTED" : "LOCAL MODE"; color: appController.boardOnline ? "#99F4D5" : "#8C98AF"; font.pixelSize: 10; font.bold: true }
                    }
                }
            }

            StackLayout {
                currentIndex: window.pageIndex
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                PlayerPage { onRequestMp3: mp3Dialog.open(); onRequestLrc: lrcDialog.open() }
                ImportPage { onRequestMp3: mp3Dialog.open(); onRequestLrc: lrcDialog.open() }
                BoardPage { }
                ExternalAudioPage { }
            }
        }
    }

    Rectangle {
        visible: appController.toastMessage.length > 0
        width: Math.min(700, toastText.implicitWidth + 58)
        height: Math.max(54, toastText.implicitHeight + 26)
        radius: 15
        color: "#F021293B"
        border.width: 1
        border.color: "#4A5875"
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 26
        z: 100
        Text { id: toastText; anchors.fill: parent; anchors.margins: 14; text: appController.toastMessage; color: "#F1F4FB"; font.pixelSize: 12; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; wrapMode: Text.WordWrap }
    }
}
