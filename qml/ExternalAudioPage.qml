import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"

Item {
    id: root
    readonly property color textPrimary: "#F4F6FF"
    readonly property color textSecondary: "#8794AD"
    readonly property color cyan: "#3FD7FF"
    readonly property int boardSource: Number(appController.boardStatus.source === undefined
                                               ? 0 : appController.boardStatus.source)

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: pageContent.implicitHeight
        flickableDirection: Flickable.VerticalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        ScrollBar.vertical: ScrollBar { }

        ColumnLayout {
        id: pageContent
        width: root.width
        spacing: 14

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 170
            Layout.minimumHeight: 170
            spacing: 14
            GlassPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                accentEdge: appController.systemAudioSignal
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 18
                    Rectangle {
                        width: 72; height: 72; radius: 22
                        gradient: Gradient {
                            GradientStop { position: 0; color: "#806BFF" }
                            GradientStop { position: 1; color: "#31CFF4" }
                        }
                        Text { anchors.centerIn: parent; text: "≋"; color: "white"; font.pixelSize: 32; font.bold: true }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 5
                        Text { text: "WINDOWS SYSTEM AUDIO"; color: root.textPrimary; font.pixelSize: 17; font.bold: true }
                        Text { text: appController.systemAudioStatus; color: appController.systemAudioAvailable ? "#63E6BC" : "#E9AC70"; font.pixelSize: 11 }
                        Text { text: "支持显示网易云音乐、QQ 音乐、浏览器和其他播放器的系统输出"; color: root.textSecondary; font.pixelSize: 10 }
                    }
                    Rectangle {
                        implicitWidth: signalText.implicitWidth + 34
                        implicitHeight: 38
                        radius: 19
                        color: appController.systemAudioSignal ? "#1746DFAE" : "#141D293D"
                        border.width: 1
                        border.color: appController.systemAudioSignal ? "#3B4DE7BA" : "#2C3851"
                        Text { id: signalText; anchors.centerIn: parent; text: appController.systemAudioSignal ? "AUDIO ACTIVE" : "NO SIGNAL"; color: appController.systemAudioSignal ? "#8CF1D0" : "#8190A9"; font.pixelSize: 10; font.bold: true }
                    }
                    Rectangle {
                        implicitWidth: boardModeText.implicitWidth + 30
                        implicitHeight: 38
                        radius: 19
                        color: root.boardSource === 2 ? "#1746DFAE" : "#141D293D"
                        border.width: 1
                        border.color: root.boardSource === 2 ? "#3B4DE7BA" : "#2C3851"
                        Text {
                            id: boardModeText
                            anchors.centerIn: parent
                            text: root.boardSource === 2 ? "BOARD: PC LINE IN"
                                  : root.boardSource === 1 ? "BOARD: QSFLASH"
                                  : "BOARD: TF CARD"
                            color: root.boardSource === 2 ? "#8CF1D0" : "#8190A9"
                            font.pixelSize: 10
                            font.bold: true
                        }
                    }
                    StudioButton { Layout.preferredWidth: 140; text: "重启监视"; symbol: "↻"; onClicked: appController.restartSystemAudioMonitor() }
                }
            }
        }

        GlassPanel {
            Layout.fillWidth: true
            Layout.preferredHeight: 480
            Layout.minimumHeight: 480
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 12
                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        spacing: 1
                        Text { text: "LIVE RAINBOW FREQUENCY FIELD"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                        Text { text: "Windows WASAPI 回环分析 • 不录音、不保存"; color: root.textSecondary; font.pixelSize: 10 }
                    }
                    Item { Layout.fillWidth: true }
                    ColumnLayout {
                        Layout.preferredWidth: 260
                        spacing: 5
                        VuMeter { Layout.fillWidth: true; implicitHeight: 11; label: "L"; level: appController.systemLeftLevel }
                        VuMeter { Layout.fillWidth: true; implicitHeight: 11; label: "R"; level: appController.systemRightLevel }
                    }
                }
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Rectangle { anchors.fill: parent; radius: 16; color: "#080D16"; border.width: 1; border.color: "#202D43" }
                    RainbowSpectrum {
                        anchors.fill: parent
                        anchors.margins: 18
                        values: appController.systemSpectrum
                        active: appController.systemAudioSignal
                        barSpacing: 5
                        // WASAPI/C++ already applies attack and release
                        // smoothing at 60 Hz.  Per-bar QML animations used to
                        // restart before completing and visibly lag behind.
                        animateChanges: false
                        particles: false
                        glowEnabled: false
                    }
                    WaveformView {
                        anchors.fill: parent
                        anchors.margins: 25
                        values: appController.systemWaveform
                        active: appController.systemAudioSignal
                        opacity: 0.60
                        strokeWidth: 1.5
                        glowRadius: 0
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 270
            Layout.minimumHeight: 270
            spacing: 14
            GlassPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumWidth: 390
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 8
                    Text { text: "让核心板播放其他软件的声音"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                    Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: "用 3.5 mm 音频线连接“电脑耳机/音频输出”与核心板 LINE_IN，然后将板端来源切换到“电脑音频”。921600 波特率串口只负责控制，不能无损传输双声道 PCM。"; color: root.textSecondary; font.pixelSize: 11 }
                    RowLayout {
                        StudioButton { Layout.preferredWidth: 230; text: root.boardSource === 2 ? "重新发送 PC LINE IN" : "切换板端到 PC LINE IN"; symbol: "▶"; primary: root.boardSource === 2; enabled: appController.boardOnline; onClicked: appController.boardSelectSource(2) }
                        StudioButton { Layout.preferredWidth: 112; text: "返回 TF卡"; visible: root.boardSource === 2; onClicked: appController.boardSelectSource(0) }
                        Rectangle { implicitWidth: inputStatus.implicitWidth + 28; implicitHeight: 36; radius: 18; color: appController.boardExternalSignal ? "#1645DEAD" : "#141E293B"; border.width: 1; border.color: appController.boardExternalSignal ? "#3A48E5B6" : "#2D3952"; Text { id: inputStatus; anchors.centerIn: parent; text: appController.boardExternalSignalKnown ? (appController.boardExternalSignal ? "LINE IN 有信号" : "LINE IN 等待信号") : "LINE IN 检测未回传"; color: appController.boardExternalSignal ? "#8EF0D0" : "#8592A8"; font.pixelSize: 10 } }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.boardSource !== 2
                              ? "板端尚未切到电脑输入；点击上方按钮后，状态应变为 BOARD: PC LINE IN。"
                              : !appController.boardExternalSignalKnown
                                ? "切换命令已发送；当前旧版9字节状态不包含LINE IN检测位，请以板端耳机/扬声器实际声音为准。"
                              : appController.boardExternalSignal
                                ? "切换命令和模拟音频输入均正常，核心板正在输出电脑声音。"
                                : "切换命令已成功；现在缺少的是电脑输出到板载 LINE_IN 的模拟音频信号。"
                        color: root.boardSource === 2 && appController.boardExternalSignal
                               ? "#74E7C2" : "#AAB5C8"
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: root.boardSource === 2
                                 && appController.systemAudioSignal
                                 && appController.boardExternalSignalKnown
                                 && !appController.boardExternalSignal
                        text: "电脑正在播放，但板端LINE IN没有信号：请检查3.5 mm音频线和LINE_IN插孔。"
                        color: "#F2B36F"
                        font.pixelSize: 10
                        wrapMode: Text.WordWrap
                    }
                }
            }

            GlassPanel {
                Layout.preferredWidth: 520
                Layout.minimumWidth: 450
                Layout.fillHeight: true
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 6
                    Text { text: "BOARD OUTPUT"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "扬声器 + PHONE OUT 音量"; color: root.textSecondary; font.pixelSize: 10 }
                        Slider { id: volume; Layout.fillWidth: true; from: 0; to: 100; value: appController.boardVolume; onMoved: appController.boardSetVolume(Math.round(value)) }
                        Text { text: Math.round(volume.value) + "%"; color: root.textPrimary; font.pixelSize: 10; Layout.preferredWidth: 36 }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "扬声器 + PHONE OUT 音色"; color: root.textSecondary; font.pixelSize: 10 }
                        Slider { id: tone; Layout.fillWidth: true; from: 0; to: 100; value: appController.boardTone; onMoved: appController.boardSetTone(Math.round(value)) }
                        Text { text: tone.value < 40 ? "低沉" : tone.value > 60 ? "明亮" : "平衡"; color: root.textPrimary; font.pixelSize: 10; Layout.preferredWidth: 36 }
                    }
                    RowLayout {
                        Switch { text: "板载扬声器"; checked: appController.boardSpeakerEnabled; onClicked: appController.boardSetSpeaker(checked) }
                        Item { Layout.fillWidth: true }
                        Text { text: "插耳机后请手动关闭扬声器"; color: "#E1B078"; font.pixelSize: 10 }
                    }
                }
            }
        }
        }
    }
}
