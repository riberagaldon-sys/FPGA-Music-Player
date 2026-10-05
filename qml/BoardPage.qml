import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "components"

Item {
    id: root
    readonly property color textPrimary: "#F4F6FF"
    readonly property color textSecondary: "#8794AD"
    readonly property color cyan: "#3FD7FF"
    readonly property string uiFont: "Microsoft YaHei UI"
    readonly property int source: Number(appController.boardStatus.source === undefined
                                         ? 0 : appController.boardStatus.source)
    function sourceName(value) {
        if (Number(value) === 1) return "QSFLASH 片段"
        if (Number(value) === 2) return "PC / LINE IN"
        return "TF CARD"
    }
    function boardSongTitle(track) {
        if (track >= 0 && track < appController.boardTfMusicFiles.length) {
            const item = appController.boardTfMusicFiles[track]
            const title = item && item.title !== undefined
                        ? String(item.title).trim() : ""
            if (title.length > 0
                    && title !== "正在读取…"
                    && title !== "USER SONG"
                    && title !== "未创建槽位"
                    && title !== "空RAW槽 / 文件无效") {
                return title
            }
        }
        if (track >= 0 && track < appController.librarySongs.length)
            return appController.librarySongs[track].title
        const userSlot = Math.max(0, track - 5)
        return "用户歌曲槽 USR" + ("0" + userSlot).slice(-2)
    }

    Connections {
        target: appController
        function onBoardCurrentLyricChanged() {
            if (appController.boardCurrentLyricIndex >= 0 && lyrics.count > 0)
                lyrics.positionViewAtIndex(appController.boardCurrentLyricIndex,
                                           ListView.Center)
        }
    }


    Popup {
        id: boardPlaylistPopup
        modal: true
        focus: true
        width: Math.min(560, root.width - 80)
        height: Math.min(560, root.height - 80)
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { radius: 18; color: "#151D2E"; border.width: 1; border.color: "#35415E" }
        contentItem: ColumnLayout {
            spacing: 10
            RowLayout {
                Layout.fillWidth: true
                Text { text: "核心板歌曲列表"; color: root.textPrimary; font.pixelSize: 18; font.bold: true }
                Item { Layout.fillWidth: true }
                Text { text: "0 - 14"; color: root.cyan; font.pixelSize: 11; font.bold: true }
            }
            ListView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: 5
                model: 15
                delegate: Rectangle {
                    required property int index
                    width: ListView.view.width
                    height: 52
                    radius: 10
                    color: index === Number(appController.boardStatus.track || 0) ? "#28315A" : "#111827"
                    RowLayout {
                        anchors.fill: parent; anchors.margins: 10
                        Text { text: index.toString().padStart(2, "0"); color: root.cyan; Layout.preferredWidth: 30 }
                        Text {
                            Layout.fillWidth: true
                            text: root.boardSongTitle(index)
                            color: root.textPrimary; elide: Text.ElideRight
                        }
                        StudioButton { minimumButtonWidth: 86; Layout.preferredWidth: 86; text: "选择"; primary: index === Number(appController.boardStatus.track || 0); onClicked: { appController.boardSelectTrack(index); boardPlaylistPopup.close() } }
                    }
                }
            }
        }
    }

    Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }

        ColumnLayout {
            id: content
            width: parent.width
            spacing: 14

            GlassPanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 150
                Layout.minimumHeight: 150
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 10
                    ColumnLayout {
                        Layout.preferredWidth: 220
                        spacing: 2
                        Text { text: "USB-UART CONNECTION"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                        Text { text: appController.serialStatus; color: appController.boardOnline ? "#6FE8C1" : root.textSecondary; font.pixelSize: 10; wrapMode: Text.WordWrap }
                    }
                    ComboBox { id: portCombo; Layout.fillWidth: true; model: appController.serialPorts; displayText: count ? currentText : "未找到串口" }
                    ComboBox { id: baudCombo; Layout.preferredWidth: 142; model: ["921600", "460800", "115200"] }
                    StudioButton {
                        Layout.preferredWidth: 140
                        text: appController.serialOpen ? "断开" : "连接"
                        primary: !appController.serialOpen
                        enabled: appController.serialOpen || portCombo.count > 0
                        onClicked: appController.serialOpen
                                   ? appController.disconnectBoard()
                                   : appController.connectBoard(portCombo.currentText,
                                                                Number(baudCombo.currentText))
                    }
                    StudioButton { minimumButtonWidth: 48; Layout.preferredWidth: 48; text: "↻"; onClicked: { appController.refreshSerialPorts(); appController.refreshStorageVolumes() } }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 820
                Layout.minimumHeight: 820
                spacing: 14

                GlassPanel {
                    Layout.preferredWidth: 520
                    Layout.minimumWidth: 470
                    Layout.fillHeight: true
                    accentEdge: appController.boardOnline
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            ColumnLayout {
                                spacing: 1
                                Text { text: "BOARD PLAYER"; color: root.cyan; font.pixelSize: 12; font.bold: true; font.letterSpacing: 1.0 }
                                Text { text: root.sourceName(root.source); color: root.textPrimary; font.pixelSize: 20; font.weight: Font.DemiBold }
                            }
                            Item { Layout.fillWidth: true }
                            Rectangle { width: 72; height: 72; radius: 36; color: "#121827"; border.width: 5; border.color: "#2C3851"; Rectangle { anchors.centerIn: parent; width: 26; height: 26; radius: 13; color: root.source === 2 ? "#42D7FF" : "#7369F8" } }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 4
                            columnSpacing: 10
                            StudioButton { id: prevButton; minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "|◀"; symbolPixelSize: 20; primary: prevButton.down; onClicked: appController.boardPrevious(); ToolTip.visible: hovered; ToolTip.text: "上一首" }
                            StudioButton { id: playButton; minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "▶"; symbolPixelSize: 20; primary: Number(appController.boardStatus.state || 0) === 1; onClicked: appController.boardPlay(); ToolTip.visible: hovered; ToolTip.text: "播放" }
                            StudioButton { id: pauseButton; minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "Ⅱ"; symbolPixelSize: 20; primary: Number(appController.boardStatus.state || 0) === 2; onClicked: appController.boardPause(); ToolTip.visible: hovered; ToolTip.text: "暂停" }
                            StudioButton { id: nextButton; minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "▶|"; symbolPixelSize: 20; primary: nextButton.down; onClicked: appController.boardNext(); ToolTip.visible: hovered; ToolTip.text: "下一首" }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: appController.formatTime(Number(appController.boardStatus.playMs || 0)); color: root.textSecondary; font.pixelSize: 10; Layout.preferredWidth: 52 }
                            Slider {
                                id: boardSeek
                                Layout.fillWidth: true
                                from: 0
                                to: Math.max(1000, appController.boardDurationMs > 0 ? appController.boardDurationMs : Number(appController.boardStatus.playMs || 0) + 1000)
                                enabled: appController.boardOnline && root.source === 0 && appController.boardDurationMs > 0
                                onPressedChanged: {
                                    if (!pressed)
                                        appController.boardSeekMs(Math.round(value))
                                }
                                ToolTip.visible: hovered
                                ToolTip.text: pressed
                                              ? "松开鼠标后跳转到 " + appController.formatTime(Math.round(value))
                                              : "拖动播放进度，松开后让FPGA跳转"
                                Binding {
                                    target: boardSeek
                                    property: "value"
                                    value: Number(appController.boardStatus.playMs || 0)
                                    when: !boardSeek.pressed
                                }
                            }
                            Text { text: appController.boardDurationMs > 0 ? appController.formatTime(appController.boardDurationMs) : "--:--"; color: root.textSecondary; font.pixelSize: 10; Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            StudioButton { minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "→"; primary: appController.boardPlaybackMode === 0; onClicked: appController.boardSetPlaybackMode(0); ToolTip.visible: hovered; ToolTip.text: "顺序播放" }
                            StudioButton { minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "ↂ"; primary: appController.boardPlaybackMode === 1; onClicked: appController.boardSetPlaybackMode(1); ToolTip.visible: hovered; ToolTip.text: "单曲循环" }
                            StudioButton { minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "↻"; primary: appController.boardPlaybackMode === 2; onClicked: appController.boardSetPlaybackMode(2); ToolTip.visible: hovered; ToolTip.text: "列表循环" }
                            StudioButton { minimumButtonWidth: 56; Layout.fillWidth: true; text: ""; symbol: "⤨"; primary: appController.boardPlaybackMode === 3; onClicked: appController.boardSetPlaybackMode(3); ToolTip.visible: hovered; ToolTip.text: "随机播放" }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "曲目槽"; color: root.textSecondary; font.pixelSize: 10 }
                            SpinBox { id: trackBox; Layout.preferredWidth: 118; from: 0; to: 14; value: Number(appController.boardStatus.track || 0); onValueModified: appController.boardSelectTrack(value) }
                            StudioButton { minimumButtonWidth: 120; Layout.preferredWidth: 132; text: "选择歌曲"; symbol: "≡"; onClicked: boardPlaylistPopup.open(); ToolTip.visible: hovered; ToolTip.text: "打开核心板播放列表并直接选歌" }
                            Item { Layout.fillWidth: true }
                            Text { text: "当前来源：" + root.sourceName(root.source); color: root.cyan; font.pixelSize: 10; font.bold: true }
                        }

                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: 10
                            rowSpacing: 10
                            StudioButton { minimumButtonWidth: 100; Layout.fillWidth: true; text: "TF卡"; primary: root.source === 0; onClicked: appController.boardSelectSource(0) }
                            StudioButton { minimumButtonWidth: 100; Layout.fillWidth: true; text: "播放 QSFLASH 片段"; primary: root.source === 1; enabled: appController.boardOnline && !appController.qspiCopyBusy; onClicked: appController.boardSelectSource(1) }
                            StudioButton { minimumButtonWidth: 100; Layout.fillWidth: true; text: "电脑 LINE IN"; primary: root.source === 2; enabled: appController.boardOnline; onClicked: appController.boardSelectSource(2) }
                            StudioButton {
                                minimumButtonWidth: 100
                                Layout.fillWidth: true
                                text: appController.qspiCopyBusy
                                      ? "正在截取并写入…"
                                      : "截取当前10秒到QSFLASH"
                                symbol: "K3"
                                enabled: appController.boardOnline
                                         && root.source === 0
                                         && !appController.qspiCopyBusy
                                         && !appController.serialUploadActive
                                onClicked: appController.boardCopySdDemoToQspi()
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "“截取当前10秒”会从当前TF卡歌曲的当前播放位置开始，把后续10秒PCM写入独立QSFLASH；“保存断点”只保存当前来源、歌曲编号、播放模式和当前时间，不会覆盖该10秒音频片段。"
                            color: appController.qspiCopyBusy ? "#F1C36D" : root.textSecondary
                            font.pixelSize: 9
                            wrapMode: Text.WordWrap
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            StudioButton { Layout.fillWidth: true; text: "保存当前播放断点"; symbol: "QS"; primary: true; enabled: appController.boardOnline && !appController.qspiCopyBusy; onClicked: appController.boardSaveResume(); ToolTip.visible: hovered; ToolTip.text: "把当前歌曲与当前播放时间写入QSFLASH" }
                            StudioButton { Layout.fillWidth: true; text: "恢复QSFLASH断点"; symbol: "↩"; enabled: appController.boardOnline && appController.boardResumeValid; onClicked: appController.boardRestoreResume(); ToolTip.visible: hovered; ToolTip.text: "恢复上次保存的歌曲和时间位置" }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: appController.boardResumeValid
                                  ? "QSFLASH断点：曲目 " + Number(appController.boardStatus.resumeTrack || 0)
                                    + " · " + appController.formatTime(Number(appController.boardStatus.resumeMs || 0))
                                  : "QSFLASH断点：尚未保存或当前固件未返回断点信息"
                            color: appController.boardResumeValid ? "#86EEC9" : root.textSecondary
                            font.pixelSize: 10
                        }

                        Text { text: "DAC 总音量（板载扬声器 + PHONE OUT）"; color: root.textSecondary; font.pixelSize: 10 }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "－"; color: root.textSecondary }
                            Timer {
                                id: boardVolumeCommit
                                interval: 25
                                repeat: true
                                onTriggered: appController.boardSetVolume(Math.round(boardVolume.value))
                            }
                            Slider {
                                id: boardVolume
                                Layout.fillWidth: true
                                from: 0
                                to: 100
                                onPressedChanged: {
                                    if (pressed) {
                                        // Apply the first value immediately, then sample at
                                        // 40 Hz while held/dragged.  This avoids both a
                                        // delayed first step and a UART frame flood.
                                        appController.boardSetVolume(Math.round(value))
                                        boardVolumeCommit.start()
                                    } else {
                                        boardVolumeCommit.stop()
                                        appController.boardSetVolume(Math.round(value))
                                    }
                                }
                                Binding {
                                    target: boardVolume
                                    property: "value"
                                    value: appController.boardVolume
                                    when: !boardVolume.pressed
                                }
                            }
                            Text { text: Math.round(boardVolume.value) + "%"; color: root.textPrimary; font.pixelSize: 10; Layout.preferredWidth: 38 }
                        }
                        Text { text: "DAC 音调 / 音色（同时作用于扬声器与 PHONE OUT）"; color: root.textSecondary; font.pixelSize: 10 }
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "LOW"; color: "#5AA9FF"; font.pixelSize: 9 }
                            Timer {
                                id: boardToneCommit
                                interval: 30
                                repeat: true
                                onTriggered: appController.boardSetTone(Math.round(tone.value))
                            }
                            Slider {
                                id: tone
                                Layout.fillWidth: true
                                from: 0
                                to: 100
                                onPressedChanged: {
                                    if (pressed) {
                                        appController.boardSetTone(Math.round(value))
                                        boardToneCommit.start()
                                    } else {
                                        boardToneCommit.stop()
                                        appController.boardSetTone(Math.round(value))
                                    }
                                }
                                Binding {
                                    target: tone
                                    property: "value"
                                    value: appController.boardTone
                                    when: !tone.pressed
                                }
                            }
                            Text { text: "HIGH"; color: "#E77AFF"; font.pixelSize: 9 }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            Switch { id: speakerSwitch; text: "板载扬声器"; checked: appController.boardSpeakerEnabled; onClicked: appController.boardSetSpeaker(checked) }
                            Item { Layout.fillWidth: true }
                            Text { text: "关闭开关只静音扬声器，PHONE OUT继续输出"; color: root.textSecondary; font.pixelSize: 10 }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: appController.boardControlsConfirmed
                                  ? "音量、音色与扬声器状态已由FPGA回传确认。"
                                  : "兼容旧版状态：Qt已发送并保留控制值；旧状态不回传音量/音色/扬声器确认。"
                            color: appController.boardControlsConfirmed ? "#67E4BE" : "#E2B37C"
                            font.pixelSize: 9
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                GlassPanel {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "BOARD LYRICS & TELEMETRY"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                            Item { Layout.fillWidth: true }
                            Rectangle { implicitWidth: tfStatus.implicitWidth + 24; implicitHeight: 30; radius: 15; color: appController.boardSdReady ? "#1641D9A5" : "#17232B3D"; border.width: 1; border.color: appController.boardSdReady ? "#3D48DFAF" : "#34415A"; Text { id: tfStatus; anchors.centerIn: parent; text: appController.boardSdReady ? (appController.boardSdReadyKnown ? "TF READY" : "TF READY · INFERRED") : (appController.boardSdReadyKnown ? "TF NOT READY" : "TF UNKNOWN"); color: appController.boardSdReady ? "#86EEC9" : "#A1AAB9"; font.pixelSize: 9; font.bold: true } }
                            Rectangle {
                                visible: appController.qspiCopyBusy
                                         || Boolean(appController.boardStatus.qspiCopyOk)
                                         || Boolean(appController.boardStatus.qspiCopyFailed)
                                implicitWidth: qspiStatus.implicitWidth + 24
                                implicitHeight: 30
                                radius: 15
                                color: appController.qspiCopyBusy ? "#25304455"
                                       : Boolean(appController.boardStatus.qspiCopyOk) ? "#1641D9A5"
                                       : "#2A3A1D28"
                                border.width: 1
                                border.color: appController.qspiCopyBusy ? "#766B62D9"
                                              : Boolean(appController.boardStatus.qspiCopyOk) ? "#3D48DFAF"
                                              : "#76516A"
                                Text {
                                    id: qspiStatus
                                    anchors.centerIn: parent
                                    text: appController.qspiCopyBusy ? "QSFLASH WRITING"
                                          : Boolean(appController.boardStatus.qspiCopyOk) ? "QSFLASH READY"
                                          : "QSFLASH FAILED"
                                    color: appController.qspiCopyBusy ? "#F2D17E"
                                           : Boolean(appController.boardStatus.qspiCopyOk) ? "#86EEC9"
                                           : "#FF8AA3"
                                    font.pixelSize: 9
                                    font.bold: true
                                }
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 90
                            Layout.minimumHeight: 90
                            radius: 14
                            color: "#101727"
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 14
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: "SOURCE"
                                        color: root.textSecondary
                                        font.pixelSize: 9
                                    }
                                    Text {
                                        text: root.sourceName(root.source)
                                        color: root.cyan
                                        font.pixelSize: 12
                                        font.bold: true
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: "TRACK"
                                        color: root.textSecondary
                                        font.pixelSize: 9
                                    }
                                    Text {
                                        text: appController.boardStatus.track === undefined
                                              ? "--" : appController.boardStatus.track
                                        color: root.textPrimary
                                        font.pixelSize: 12
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: "PLAY TIME"
                                        color: root.textSecondary
                                        font.pixelSize: 9
                                    }
                                    Text {
                                        text: appController.formatTime(
                                                  Number(appController.boardStatus.playMs || 0))
                                        color: root.textPrimary
                                        font.pixelSize: 12
                                    }
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: "ERROR"
                                        color: root.textSecondary
                                        font.pixelSize: 9
                                    }
                                    Text {
                                        text: "0x" + ("0" + Number(appController.boardStatus.error || 0).toString(16)).slice(-2)
                                        color: Number(appController.boardStatus.error || 0)
                                               ? "#FF718E" : "#5DE5B5"
                                        font.pixelSize: 12
                                    }
                                }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: Number(appController.boardStatus.error || 0) !== 0
                            text: appController.boardErrorDescription(
                                      Number(appController.boardStatus.error || 0))
                            color: "#F2A1B1"
                            font.pixelSize: 10
                            wrapMode: Text.WordWrap
                        }
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            ListView {
                                id: lyrics
                                anchors.fill: parent
                                visible: root.source !== 2
                                clip: true
                                model: appController.boardLyricLines
                                currentIndex: appController.boardCurrentLyricIndex
                                delegate: Item {
                                    required property int index
                                    required property string modelData
                                    width: ListView.view.width
                                    height: index === appController.boardCurrentLyricIndex ? 46 : 34
                                    Text { anchors.fill: parent; anchors.leftMargin: 12; verticalAlignment: Text.AlignVCenter; text: modelData; color: index === appController.boardCurrentLyricIndex ? "#FFFFFF" : "#68758D"; font.family: root.uiFont; font.pixelSize: index === appController.boardCurrentLyricIndex ? 17 : 12; font.bold: index === appController.boardCurrentLyricIndex; elide: Text.ElideRight }
                                }
                            }
                            Column {
                                visible: root.source !== 2
                                         && appController.boardLyricLines.length === 0
                                anchors.centerIn: parent
                                width: Math.min(parent.width - 40, 520)
                                spacing: 8
                                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; text: "没有可显示的板端歌词"; color: root.textPrimary; font.pixelSize: 20; font.bold: true }
                                Text { width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; text: appController.boardLyricStatus; color: root.textSecondary; font.pixelSize: 11 }
                            }
                            Column {
                                visible: root.source === 2
                                anchors.centerIn: parent
                                spacing: 8
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: appController.boardExternalSignalKnown ? (appController.boardExternalSignal ? "检测到电脑 LINE IN 音频" : "等待电脑 LINE IN 音频") : "电脑 LINE IN 已选择"; color: appController.boardExternalSignal ? "#60E3BB" : root.textPrimary; font.pixelSize: 20; font.bold: true }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: appController.boardExternalSignalKnown ? "FPGA正在回传输入检测状态" : "旧版状态不回传LINE IN检测；频谱使用Windows回环信号"; color: root.textSecondary; font.pixelSize: 11 }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: "歌词由正在使用的外部播放器显示"; color: root.textSecondary; font.pixelSize: 11 }
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            VuMeter { Layout.fillWidth: true; implicitHeight: 12; label: "L"; level: appController.boardLeftLevel }
                            VuMeter { Layout.fillWidth: true; implicitHeight: 12; label: "R"; level: appController.boardRightLevel }
                        }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 260
                Layout.minimumHeight: 260
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 20
                    spacing: 8
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "FPGA PLAYBACK VISUALIZER"; color: root.textPrimary; font.pixelSize: 13; font.bold: true }
                        Item { Layout.fillWidth: true }
                        Text { text: appController.boardVisualizationMode; color: root.cyan; font.pixelSize: 9; font.bold: true }
                        Text { text: "FIFO  " + Number(appController.boardStatus.fifoPercent || 0) + "%"; color: root.textSecondary; font.pixelSize: 10 }
                    }
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        RainbowSpectrum { anchors.fill: parent; values: appController.boardSpectrum; active: appController.boardVisualizationActive; barSpacing: 5 }
                        WaveformView { anchors.fill: parent; anchors.margins: 8; values: appController.boardWaveform; active: appController.boardVisualizationActive; opacity: 0.52 }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 170
                Layout.minimumHeight: 170
                accentEdge: appController.serialUploadActive
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 14
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 7
                        Text { text: "BOARD TF PACKAGE UPLOAD"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                        Text { Layout.fillWidth: true; text: appController.generatedPackagePath.length ? appController.generatedPackagePath : "在“歌曲导入”页先生成歌曲包"; color: root.textSecondary; font.pixelSize: 10; elide: Text.ElideMiddle }
                        ProgressBar { Layout.fillWidth: true; from: 0; to: 1; value: appController.serialUploadProgress }
                        Text {
                            Layout.fillWidth: true
                            text: (appController.serialUploadActive ? appController.serialStatus : appController.taskStatus)
                                  + "  ·  曲目" + uploadTrack.value + " → "
                                  + appController.userSlotFileName(uploadTrack.value)
                            color: appController.serialStatus.indexOf("失败") >= 0 ? "#FF819A" : root.textSecondary
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                    ColumnLayout {
                        spacing: 4
                        Text { text: "板端曲目（5–14）"; color: root.textSecondary; font.pixelSize: 9 }
                        SpinBox { id: uploadTrack; Layout.preferredWidth: 130; from: 5; to: 14; value: 5 }
                    }
                    StudioButton {
                        Layout.preferredWidth: 150
                        visible: appController.serialUploadActive
                        text: "停止上传"
                        onClicked: appController.cancelCurrentTask()
                    }
                    StudioButton { Layout.preferredWidth: 180; text: "上传当前包"; symbol: "⇧"; primary: true; enabled: appController.boardOnline && appController.generatedPackagePath.length > 0 && !appController.serialUploadActive; onClicked: appController.uploadGeneratedPackage(uploadTrack.value) }
                }
            }

            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 56; Layout.minimumHeight: 56; radius: 12; color: "#1A261F24"; border.width: 1; border.color: "#473F384A"; Text { anchors.fill: parent; anchors.margins: 12; verticalAlignment: Text.AlignVCenter; text: "耳机座没有插入检测信号接到 FPGA，因此自动静音扬声器无法由程序判断；请使用上面的“板载扬声器”开关。"; color: "#E2B37C"; font.pixelSize: 10; wrapMode: Text.WordWrap } }
        }
    }
}
