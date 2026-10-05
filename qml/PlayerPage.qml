import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"

Item {
    id: root
    signal requestMp3()
    signal requestLrc()

    readonly property color textPrimary: "#F4F6FF"
    readonly property color textSecondary: "#8794AD"
    readonly property color purple: "#7167F6"
    readonly property color cyan: "#3FD7FF"
    readonly property string uiFont: "Microsoft YaHei UI"

    Connections {
        target: appController
        function onCurrentLyricChanged() {
            if (appController.currentLyricIndex >= 0)
                lyricList.positionViewAtIndex(appController.currentLyricIndex,
                                              ListView.Center)
        }
    }


    Popup {
        id: playlistPopup
        modal: true
        focus: true
        width: Math.min(520, root.width - 80)
        height: Math.min(520, root.height - 80)
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { radius: 18; color: "#151D2E"; border.width: 1; border.color: "#35415E" }
        contentItem: ColumnLayout {
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Text { text: "播放列表"; color: root.textPrimary; font.pixelSize: 18; font.bold: true }
                Item { Layout.fillWidth: true }
                Text { text: appController.librarySongs.length + " 首"; color: root.cyan; font.pixelSize: 11; font.bold: true }
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 6
                model: appController.librarySongs
                delegate: Rectangle {
                    required property int index
                    required property var modelData
                    width: ListView.view.width
                    height: 56
                    radius: 10
                    color: index === appController.currentLibraryIndex ? "#28315A" : "#111827"
                    border.width: index === appController.currentLibraryIndex ? 1 : 0
                    border.color: root.purple
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        Text { text: (index + 1).toString().padStart(2, "0"); color: root.cyan; font.pixelSize: 10; Layout.preferredWidth: 28 }
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            Text { Layout.fillWidth: true; text: modelData.title || "未命名歌曲"; color: root.textPrimary; font.pixelSize: 13; font.bold: true; elide: Text.ElideRight }
                            Text { Layout.fillWidth: true; text: modelData.artist || ""; color: root.textSecondary; font.pixelSize: 10; elide: Text.ElideRight }
                        }
                        StudioButton { minimumButtonWidth: 76; Layout.preferredWidth: 76; text: "播放"; primary: index === appController.currentLibraryIndex; onClicked: { appController.selectLocalSong(index); playlistPopup.close() } }
                    }
                }
            }
        }
    }

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
            Layout.preferredHeight: 52
            spacing: 12
            ComboBox {
                id: libraryCombo
                Layout.fillWidth: true
                Layout.minimumWidth: 250
                Layout.maximumWidth: 390
                model: appController.librarySongs
                textRole: "title"
                displayText: count > 0 ? currentText : "未找到配套歌曲"
            }
            StudioButton {
                Layout.preferredWidth: 132
                text: "载入曲库"
                symbol: "↧"
                enabled: libraryCombo.count > 0
                onClicked: appController.loadLibrarySong(libraryCombo.currentIndex)
            }
            StudioButton { Layout.preferredWidth: 132; text: "选择 MP3"; symbol: "♫"; onClicked: root.requestMp3() }
            StudioButton { Layout.preferredWidth: 132; text: "选择 LRC"; symbol: "≡"; onClicked: root.requestLrc() }
            Item { Layout.fillWidth: true }
            Rectangle {
                Layout.preferredWidth: 132
                Layout.preferredHeight: 36
                implicitWidth: sourceText.implicitWidth + 28
                implicitHeight: 34
                radius: 17
                color: "#182235"
                border.width: 1
                border.color: "#2B3854"
                Text {
                    id: sourceText
                    anchors.centerIn: parent
                    text: "LOCAL PLAYER"
                    color: root.cyan
                    font.pixelSize: 10
                    font.bold: true
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 560
            Layout.minimumHeight: 560
            spacing: 14

            GlassPanel {
                Layout.preferredWidth: 430
                Layout.fillHeight: true
                accentEdge: appController.playing

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 9

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 205

                        Rectangle {
                            width: Math.min(parent.width, parent.height) * 0.90
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "#197269FF"
                            scale: 1 + appController.peakLevel * 0.14
                            Behavior on scale { NumberAnimation { duration: 85 } }
                        }
                        Rectangle {
                            id: disc
                            width: Math.min(parent.width, parent.height) * 0.73
                            height: width
                            radius: width / 2
                            anchors.centerIn: parent
                            color: "#0D111B"
                            border.width: 1
                            border.color: "#46516A"
                            RotationAnimator on rotation {
                                from: 0; to: 360; duration: 14000
                                loops: Animation.Infinite
                                running: appController.playing
                            }
                            Repeater {
                                model: 9
                                Rectangle {
                                    required property int index
                                    anchors.centerIn: parent
                                    width: disc.width * (0.94 - index * 0.075)
                                    height: width
                                    radius: width / 2
                                    color: "transparent"
                                    border.width: 1
                                    border.color: index % 2 ? "#182432" : "#263244"
                                }
                            }
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width * 0.33
                                height: width
                                radius: width / 2
                                gradient: Gradient {
                                    GradientStop { position: 0; color: "#846DFF" }
                                    GradientStop { position: 0.55; color: "#625DF0" }
                                    GradientStop { position: 1; color: "#35D1F6" }
                                }
                                Text { anchors.centerIn: parent; text: "GX"; color: "white"; font.pixelSize: 22; font.bold: true }
                            }
                            Rectangle { anchors.centerIn: parent; width: 11; height: 11; radius: 6; color: "#090D17" }
                        }
                    }

                    Text { Layout.fillWidth: true; text: appController.title; color: root.textPrimary; font.pixelSize: 20; font.weight: Font.DemiBold; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
                    Text { Layout.fillWidth: true; text: appController.artist; color: root.textSecondary; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }

                    Slider {
                        id: seek
                        Layout.fillWidth: true
                        from: 0
                        to: Math.max(1, appController.duration)
                        enabled: appController.duration > 0
                        onPressedChanged: {
                            if (!pressed && appController.duration > 0)
                                appController.seekNormalized(value / Math.max(1, to))
                        }
                        ToolTip.visible: hovered
                        ToolTip.text: pressed
                                      ? "松开后跳转到 " + appController.formatTime(Math.round(value))
                                      : "拖动播放进度"
                        Binding {
                            target: seek
                            property: "value"
                            value: appController.position
                            when: !seek.pressed
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: appController.formatTime(appController.position); color: root.textSecondary; font.pixelSize: 10 }
                        Item { Layout.fillWidth: true }
                        Text { text: appController.formatTime(appController.duration); color: root.textSecondary; font.pixelSize: 10 }
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredHeight: 76
                        spacing: 12
                        StudioButton {
                            minimumButtonWidth: 44; Layout.preferredWidth: 44; Layout.preferredHeight: 42
                            text: ""; symbol: "■"; symbolPixelSize: 18; font.pixelSize: 20
                            onClicked: appController.stopPlayback()
                            ToolTip.visible: hovered; ToolTip.text: "停止播放"; ToolTip.delay: 250
                        }
                        StudioButton {
                            minimumButtonWidth: 50; Layout.preferredWidth: 50; Layout.preferredHeight: 42
                            text: ""; symbol: "|◀"; symbolPixelSize: 21; font.pixelSize: 22
                            onClicked: appController.previousLocalSong()
                            ToolTip.visible: hovered; ToolTip.text: "上一首"; ToolTip.delay: 250
                        }
                        StudioButton {
                            minimumButtonWidth: 72; Layout.preferredWidth: 72; Layout.preferredHeight: 52
                            text: ""; symbol: appController.playing ? "Ⅱ" : "▶"; symbolPixelSize: 25; font.pixelSize: 26; primary: true
                            onClicked: appController.togglePlay()
                            ToolTip.visible: hovered; ToolTip.text: appController.playing ? "暂停播放" : "开始播放"; ToolTip.delay: 250
                        }
                        StudioButton {
                            minimumButtonWidth: 50; Layout.preferredWidth: 50; Layout.preferredHeight: 42
                            text: ""; symbol: "▶|"; symbolPixelSize: 21; font.pixelSize: 22
                            onClicked: appController.nextLocalSong()
                            ToolTip.visible: hovered; ToolTip.text: "下一首"; ToolTip.delay: 250
                        }
                        StudioButton {
                            minimumButtonWidth: 44; Layout.preferredWidth: 44; Layout.preferredHeight: 42
                            text: ""; symbol: "≡"; symbolPixelSize: 20; font.pixelSize: 20
                            onClicked: playlistPopup.open()
                            ToolTip.visible: hovered; ToolTip.text: "打开歌曲列表 / 直接选歌"; ToolTip.delay: 250
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 4
                        StudioButton { minimumButtonWidth: 48; Layout.preferredWidth: 48; Layout.alignment: Qt.AlignHCenter;
                             text: ""; symbol: "→"; primary: appController.playbackMode === 0; onClicked: appController.setPlaybackMode(0); ToolTip.visible: hovered; ToolTip.delay: 250; ToolTip.text: "顺序播放：最后一首播放完停止" }
                        StudioButton { minimumButtonWidth: 48; Layout.preferredWidth: 48; text: ""; symbol: "ↂ"; primary: appController.playbackMode === 1; onClicked: appController.setPlaybackMode(1); ToolTip.visible: hovered; ToolTip.delay: 250; ToolTip.text: "单曲循环" }
                        StudioButton { minimumButtonWidth: 48; Layout.preferredWidth: 48; text: ""; symbol: "↻"; primary: appController.playbackMode === 2; onClicked: appController.setPlaybackMode(2); ToolTip.visible: hovered; ToolTip.delay: 250; ToolTip.text: "列表循环" }
                        StudioButton { minimumButtonWidth: 48; Layout.preferredWidth: 48; text: ""; symbol: "⤨"; primary: appController.playbackMode === 3; onClicked: appController.setPlaybackMode(3); ToolTip.visible: hovered; ToolTip.delay: 250; ToolTip.text: "随机播放" }
                    }
                    Text { Layout.fillWidth: true; text: "播放模式 · " + appController.playbackModeName; horizontalAlignment: Text.AlignHCenter; color: root.textSecondary; font.pixelSize: 10 }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { Layout.preferredWidth: 64; text: "音量"; color: root.textSecondary; font.pixelSize: 10 }
                        Slider { Layout.fillWidth: true; from: 0; to: 1; value: appController.volume; onMoved: appController.volume = value }
                        Text { text: Math.round(appController.volume * 100) + "%"; color: root.textPrimary; font.pixelSize: 10; Layout.preferredWidth: 46; horizontalAlignment: Text.AlignRight }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { Layout.preferredWidth: 64; text: "速度/音调"; color: root.textSecondary; font.pixelSize: 10 }
                        Slider { Layout.fillWidth: true; from: 0.75; to: 1.25; stepSize: 0.01; value: appController.playbackRate; onMoved: appController.playbackRate = value }
                        Text { text: appController.playbackRate.toFixed(2) + "×"; color: root.textPrimary; font.pixelSize: 10; Layout.preferredWidth: 46; horizontalAlignment: Text.AlignRight }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 24
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            spacing: 1
                            Text { text: "LIVE LYRICS"; color: root.cyan; font.pixelSize: 12; font.bold: true; font.letterSpacing: 1.0 }
                            Text { text: "LRC 时间轴自动定位，当前句高亮"; color: root.textSecondary; font.pixelSize: 10 }
                        }
                        Item { Layout.fillWidth: true }
                        Text { text: appController.lyricLines.length + " LINES"; color: "#7E8BA4"; font.pixelSize: 10 }
                    }

                    ListView {
                        id: lyricList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 3
                        model: appController.lyricLines
                        currentIndex: appController.currentLyricIndex
                        preferredHighlightBegin: height * 0.42
                        preferredHighlightEnd: height * 0.58
                        highlightRangeMode: ListView.ApplyRange
                        highlightMoveDuration: 280
                        delegate: Item {
                            required property int index
                            required property string modelData
                            width: ListView.view.width
                            height: active ? 54 : 40
                            readonly property bool active: index === appController.currentLyricIndex
                            Rectangle {
                                anchors.fill: parent
                                radius: 10
                                color: parent.active ? "#20736AFF" : "transparent"
                                border.width: parent.active ? 1 : 0
                                border.color: "#4A7C72FF"
                            }
                            Text {
                                anchors.fill: parent
                                anchors.leftMargin: 15
                                anchors.rightMargin: 15
                                verticalAlignment: Text.AlignVCenter
                                text: modelData
                                color: parent.active ? "#FFFFFF" : "#6F7C94"
                                font.family: root.uiFont
                                font.pixelSize: parent.active ? 20 : 14
                                font.weight: parent.active ? Font.DemiBold : Font.Normal
                                elide: Text.ElideRight
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: appController.lyricLines.length === 0
                            text: "选择 MP3 和 LRC 后开始播放"
                            color: root.textPrimary
                            font.pixelSize: 22
                            font.bold: true
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 45
                        radius: 11
                        color: "#101727"
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 11
                            Text { text: "LCD"; color: root.purple; font.pixelSize: 10; font.bold: true }
                            Text { Layout.fillWidth: true; text: appController.currentBoardPreview; color: "#98A6BE"; font.family: root.uiFont; font.pixelSize: 10; elide: Text.ElideRight }
                        }
                    }
                }
            }
        }

        GlassPanel {
            Layout.fillWidth: true
            Layout.preferredHeight: 235
            Layout.minimumHeight: 235
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 8
                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "REAL-TIME RAINBOW SPECTRUM"; color: root.textPrimary; font.pixelSize: 13; font.bold: true }
                    Item { Layout.fillWidth: true }
                    ColumnLayout {
                        Layout.preferredWidth: 220
                        spacing: 4
                        VuMeter { Layout.fillWidth: true; implicitHeight: 10; label: "L"; level: appController.leftLevel }
                        VuMeter { Layout.fillWidth: true; implicitHeight: 10; label: "R"; level: appController.rightLevel }
                    }
                }
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    RainbowSpectrum { anchors.fill: parent; values: appController.spectrum; active: appController.playing && appController.peakLevel > 0.0025; barSpacing: 5 }
                    WaveformView { anchors.fill: parent; anchors.margins: 8; values: appController.waveform; active: appController.playing && appController.peakLevel > 0.0025; opacity: 0.55 }
                }
            }
        }
        }
    }
}
