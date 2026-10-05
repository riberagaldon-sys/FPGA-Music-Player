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
    readonly property color cyan: "#3FD7FF"
    readonly property bool pcTarget: targetMode.currentIndex === 0
    readonly property int selectedTrack: trackBox.value
    readonly property bool selectedVolumeCompatible:
        volumeCombo.currentIndex >= 0
        && volumeCombo.currentIndex < appController.storageVolumes.length
        && Boolean(appController.storageVolumes[volumeCombo.currentIndex].writeCompatible)

    Component.onCompleted: {
        appController.refreshStorageVolumes()
        appController.refreshMusicDirectories("")
        if (!root.pcTarget && appController.boardOnline && appController.boardSdReady)
            appController.refreshBoardTfDirectory()
    }

    Connections {
        target: appController
        function onBoardStatusChanged() {
            if (!root.pcTarget && appController.boardOnline
                    && appController.boardSdReady
                    && !appController.boardTfScanActive
                    && appController.boardTfMusicFiles.length === 0)
                appController.refreshBoardTfDirectory()
        }
    }

    Dialog {
        id: initializeDialog
        modal: true
        anchors.centerIn: parent
        width: 540
        title: "建立 TF 卡 RAW 用户槽"
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: appController.initializeSdSlots(volumeCombo.currentValue,
                                                     slotCount.value)
        contentItem: ColumnLayout {
            spacing: 12
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: root.textPrimary; text: "建立 " + slotCount.value + " 个 RAW 用户文件（USR00.RAW 起）。RAW 为 44.1 kHz / 16-bit / Stereo / signed little-endian PCM，不再生成 GXM。" }
            Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: "#FFB66B"; text: "注意：同名 USRxx.RAW 会被清空重建；LRC 使用同名侧文件。请确认选中的是 TF 卡盘符。" }
            SpinBox { id: slotCount; from: 1; to: 10; value: 10 }
        }
        background: Rectangle { radius: 18; color: "#171E30"; border.color: "#36425F" }
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
                Layout.preferredHeight: 180
                Layout.minimumHeight: 180
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 12
                    Text { text: "01  选择配套文件"; color: root.textPrimary; font.pixelSize: 15; font.bold: true }
                    RowLayout {
                        Layout.fillWidth: true
                        StudioButton { Layout.preferredWidth: 150; text: "选择 MP3"; symbol: "♫"; primary: true; onClicked: root.requestMp3() }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 44; radius: 11; color: "#101727"; border.width: 1; border.color: "#26334F"
                            Text { anchors.fill: parent; anchors.margins: 12; verticalAlignment: Text.AlignVCenter; text: appController.displayPath(appController.mp3Path); color: appController.mp3Path.length ? "#B8C4D8" : "#59657D"; font.pixelSize: 11; elide: Text.ElideMiddle }
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        StudioButton { Layout.preferredWidth: 150; text: "选择 LRC"; symbol: "≡"; onClicked: root.requestLrc() }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 44; radius: 11; color: "#101727"; border.width: 1; border.color: "#26334F"
                            Text { anchors.fill: parent; anchors.margins: 12; verticalAlignment: Text.AlignVCenter; text: appController.displayPath(appController.lrcPath); color: appController.lrcPath.length ? "#B8C4D8" : "#59657D"; font.pixelSize: 11; elide: Text.ElideMiddle }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.preferredHeight: 320
                Layout.minimumHeight: 320
                spacing: 14

                GlassPanel {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 360
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 10
                        Text { text: "02  歌曲信息"; color: root.textPrimary; font.pixelSize: 15; font.bold: true }
                        Text { text: "歌曲名（LCD 会自动截取 16 字符）"; color: root.textSecondary; font.pixelSize: 10 }
                        TextField { Layout.fillWidth: true; implicitHeight: 43; text: appController.title; color: root.textPrimary; onEditingFinished: appController.title = text; background: Rectangle { radius: 11; color: "#101727"; border.width: 1; border.color: "#283550" } }
                        Text { text: "歌手"; color: root.textSecondary; font.pixelSize: 10 }
                        TextField { Layout.fillWidth: true; implicitHeight: 43; text: appController.artist; color: root.textPrimary; onEditingFinished: appController.artist = text; background: Rectangle { radius: 11; color: "#101727"; border.width: 1; border.color: "#283550" } }
                    }
                }

                GlassPanel {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumWidth: 430
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 22
                        spacing: 10
                        RowLayout {
                            Layout.fillWidth: true
                            Text { text: "03  写入目标与槽位"; color: root.textPrimary; font.pixelSize: 15; font.bold: true }
                            Item { Layout.fillWidth: true }
                            Text { text: "板端曲目"; color: root.textSecondary; font.pixelSize: 10 }
                            SpinBox { id: trackBox; from: 0; to: 14; value: 0 }
                        }
                        ComboBox {
                            id: targetMode
                            Layout.fillWidth: true
                            currentIndex: 1
                            model: ["电脑读卡器（直接写入 TF 卡）",
                                    "板载 TF 卡（通过 FPGA 串口读写）"]
                            onCurrentIndexChanged: {
                                if (currentIndex === 1 && appController.boardOnline)
                                    appController.refreshBoardTfDirectory()
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.pcTarget
                            ComboBox {
                                id: volumeCombo
                                Layout.fillWidth: true
                                model: appController.storageVolumes
                                textRole: "display"
                                valueRole: "root"
                                displayText: count ? currentText : "没有检测到电脑读卡器中的 FAT / exFAT TF 卡"
                                onCurrentValueChanged: appController.refreshMusicDirectories(currentValue || "")
                            }
                            StudioButton {
                                minimumButtonWidth: 48; Layout.preferredWidth: 48; text: "↻"
                                ToolTip.visible: hovered; ToolTip.text: "重新扫描电脑上的TF卡盘符"
                                onClicked: appController.refreshStorageVolumes()
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.pcTarget
                            StudioButton { Layout.preferredWidth: 160; text: "建立 RAW 用户槽"; enabled: volumeCombo.count > 0 && root.selectedVolumeCompatible && !appController.busy; onClicked: initializeDialog.open() }
                            Text { Layout.fillWidth: true; text: volumeCombo.count === 0 ? "把TF卡插入电脑读卡器后点刷新；插在板上不会显示Windows盘符。" : (root.selectedVolumeCompatible ? "FAT32：根目录只保存歌曲RAW和同名LRC；不再写GXM或MP3副本。" : "此盘电脑可读，但 FPGA 需要 FAT32，不能直接写板端歌曲包。"); color: root.selectedVolumeCompatible ? "#67E4BE" : "#F4B56A"; font.pixelSize: 10; wrapMode: Text.WordWrap }
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            visible: !root.pcTarget
                            implicitHeight: 52
                            radius: 12
                            color: appController.boardSdReady ? "#142A303B" : "#151F2738"
                            border.width: 1
                            border.color: appController.boardSdReady ? "#3A44DCAA" : "#34405A"
                            RowLayout {
                                anchors.fill: parent; anchors.margins: 12
                                Rectangle { width: 8; height: 8; radius: 4; color: appController.boardSdReady ? "#47E5B2" : "#EEA763" }
                                Text { Layout.fillWidth: true; text: appController.boardSdReady ? "板载TF卡" + (appController.boardSdReadyKnown ? "已确认就绪" : "按旧协议状态推断可用") + "；RAW固件支持板载串口上传，并可在TF卡上自动创建USRxx.RAW及FAT簇链，不需要先拔卡初始化。" : (appController.boardSdReadyKnown ? "板载TF卡明确未就绪，请检查FAT32卡" : "旧版状态未提供TF卡标志；仍可尝试上传，板端ACK会返回准确结果"); color: appController.boardSdReady ? "#9AF0D2" : "#EAB37A"; font.pixelSize: 11; wrapMode: Text.WordWrap }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.pcTarget
                                  ? ("电脑读卡器写入：曲目 " + trackBox.value + " → "
                                     + appController.userSlotFileName(trackBox.value)
                                     + " / " + appController.userSlotFileName(trackBox.value).replace(/\.RAW$/i, ".LRC"))
                                  : ("板载串口覆盖：曲目 " + trackBox.value + " → "
                                     + appController.userSlotFileName(trackBox.value)
                                     + "。板上的TF卡不会显示Windows盘符，也不需要这里选择盘符。")
                            color: root.cyan
                            font.pixelSize: 10
                            font.bold: true
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 360
                Layout.minimumHeight: 360
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "04  歌曲目录与删除管理"; color: root.textPrimary; font.pixelSize: 15; font.bold: true }
                        Item { Layout.fillWidth: true }
                        StudioButton {
                            minimumButtonWidth: 100; Layout.preferredWidth: 110; text: "刷新目录"; symbol: "↻"
                            onClicked: {
                                if (root.pcTarget) {
                                    appController.refreshStorageVolumes()
                                    appController.refreshMusicDirectories(volumeCombo.count ? volumeCombo.currentValue : "")
                                } else {
                                    appController.refreshBoardTfDirectory()
                                }
                            }
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.pcTarget
                              ? "电脑读卡器模式：右侧显示Windows能直接访问的TF卡根目录，可删除RAW/LRC。"
                              : "板载TF卡模式：曲目槽0~14都可以直接选择、覆盖和删除；0~4对应原有RAW文件，5~14对应USR00.RAW~USR09.RAW。"
                        color: root.textSecondary; font.pixelSize: 10; wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 12
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; radius: 12; color: "#0E1523"; border.width: 1; border.color: "#26334F"
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 12; spacing: 6
                                Text { text: "电脑本地音乐库  ·  " + appController.localMusicFiles.length + " 首"; color: root.cyan; font.pixelSize: 12; font.bold: true }
                                Text { Layout.fillWidth: true; text: "配套歌曲 + 当前导入MP3所在目录（按歌曲显示，不再把LRC单独算一首）"; color: root.textSecondary; font.pixelSize: 9; elide: Text.ElideMiddle }
                                ListView {
                                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
                                    model: appController.localMusicFiles
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: ListView.view.width; height: 42; radius: 8; color: "#121B2C"
                                        RowLayout {
                                            anchors.fill: parent; anchors.margins: 7
                                            Text { Layout.fillWidth: true; text: modelData.name; color: root.textPrimary; font.pixelSize: 10; elide: Text.ElideMiddle }
                                            StudioButton { minimumButtonWidth: 68; Layout.preferredWidth: 72; Layout.preferredHeight: 32; text: "删除"; danger: true; onClicked: appController.deleteLocalMusicFile(modelData.path) }
                                        }
                                    }
                                }
                            }
                        }
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; radius: 12; color: "#0E1523"; border.width: 1; border.color: "#26334F"
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 12; spacing: 6
                                Text {
                                    text: root.pcTarget ? "电脑读卡器 TF 卡根目录" : "板载 TF 卡根目录歌曲"
                                    color: root.cyan; font.pixelSize: 12; font.bold: true
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: root.pcTarget
                                          ? (volumeCombo.count ? volumeCombo.currentValue : "未选择电脑读卡器中的TF卡")
                                          : (appController.boardTfScanActive
                                             ? "正在通过FPGA读取TF卡根目录…"
                                             : appController.boardSdReady
                                               ? "TF卡已就绪 · 已读取 " + appController.boardTfMusicFiles.length + "/15 个RAW曲目"
                                               : "FPGA尚未检测到TF卡")
                                    color: root.textSecondary; font.pixelSize: 9; elide: Text.ElideMiddle
                                }
                                ListView {
                                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
                                    visible: root.pcTarget
                                    model: appController.sdMusicFiles
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: ListView.view.width; height: 42; radius: 8; color: "#121B2C"
                                        RowLayout {
                                            anchors.fill: parent; anchors.margins: 7
                                            Text { Layout.fillWidth: true; text: modelData.display; color: root.textPrimary; font.pixelSize: 10; elide: Text.ElideMiddle }
                                            Text { text: modelData.files ? modelData.files.length + " 文件" : ""; color: root.textSecondary; font.pixelSize: 9 }
                                            StudioButton { minimumButtonWidth: 68; Layout.preferredWidth: 72; Layout.preferredHeight: 32; text: "删除"; danger: true; onClicked: appController.deleteSdSong(modelData.baseName, volumeCombo.currentValue) }
                                        }
                                    }
                                }
                                ListView {
                                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 4
                                    visible: !root.pcTarget
                                    model: appController.boardTfMusicFiles
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: ListView.view.width; height: 48; radius: 8; color: "#121B2C"
                                        RowLayout {
                                            anchors.fill: parent; anchors.margins: 7; spacing: 8
                                            ColumnLayout {
                                                Layout.fillWidth: true; spacing: 1
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: modelData.error === -1
                                                          ? "正在读取…"
                                                          : modelData.error === 254
                                                            ? "查询超时"
                                                            : modelData.error === 255
                                                              ? "查询发送失败"
                                                              : modelData.builtin
                                                                ? (modelData.present ? modelData.title : "内置RAW文件缺失")
                                                                : modelData.valid
                                                                  ? modelData.title
                                                                  : modelData.present
                                                                    ? "空RAW槽 / 文件无效"
                                                                  : modelData.error === 3
                                                                    ? "未创建歌曲槽"
                                                                    : "TF卡读取失败 0x" + Number(modelData.error).toString(16)
                                                    color: modelData.valid ? root.textPrimary : root.textSecondary
                                                    font.pixelSize: 10; font.bold: modelData.valid; elide: Text.ElideRight
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: (modelData.builtin ? "内置RAW · 曲目 " : "用户RAW · 曲目 ")
                                                          + modelData.track + "  ·  " + modelData.fileName
                                                          + ((modelData.builtin ? modelData.present : modelData.valid) ? "  ·  可播放" : "")
                                                    color: root.textSecondary; font.pixelSize: 8; elide: Text.ElideRight
                                                }
                                            }
                                            StudioButton {
                                                minimumButtonWidth: 62; Layout.preferredWidth: 66; Layout.preferredHeight: 32
                                                text: "选择"
                                                onClicked: trackBox.value = modelData.track
                                            }
                                            StudioButton {
                                                minimumButtonWidth: 68; Layout.preferredWidth: 72; Layout.preferredHeight: 32
                                                text: modelData.builtin ? "删除" : "清空"
                                                danger: true
                                                visible: true
                                                enabled: appController.boardOnline && appController.boardSdReady
                                                         && modelData.present && !appController.serialUploadActive
                                                         && !appController.boardTfScanActive
                                                ToolTip.visible: hovered
                                                ToolTip.text: modelData.builtin
                                                              ? "板载安全删除：把该RAW文件长度置0并保留已分配簇，避免破坏FAT链"
                                                              : "清空RAW槽并保留簇链，之后仍可板载覆盖上传"
                                                onClicked: appController.boardClearSlot(modelData.track)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 165
                Layout.minimumHeight: 165
                accentEdge: appController.busy || appController.serialUploadActive
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 14
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text { text: appController.serialUploadActive ? appController.serialStatus : appController.taskStatus; color: root.textPrimary; font.pixelSize: 13; font.bold: true }
                        ProgressBar { Layout.fillWidth: true; from: 0; to: 1; value: appController.serialUploadActive ? appController.serialUploadProgress : appController.taskProgress }
                        Text { Layout.fillWidth: true; text: appController.generatedPackagePath.length ? "生成文件：" + appController.generatedPackagePath : "输出：44.1 kHz / signed 16-bit LE / stereo RAW；歌词保存为同名LRC"; color: root.textSecondary; font.pixelSize: 10; elide: Text.ElideMiddle }
                    }
                    StudioButton {
                        Layout.preferredWidth: 160
                        visible: appController.busy || appController.serialUploadActive
                        text: "停止当前任务"
                        onClicked: appController.cancelCurrentTask()
                    }
                    StudioButton { Layout.preferredWidth: 180; text: "仅生成 RAW"; enabled: !appController.busy && !appController.serialUploadActive; onClicked: appController.buildPackage(trackBox.value, "") }
                    StudioButton {
                        Layout.preferredWidth: 210
                        text: root.pcTarget ? "转换并写入 RAW" : "转换并上传板载 TF 卡"
                        symbol: root.pcTarget ? "⇩" : "⇧"
                        primary: true
                        enabled: !appController.busy && !appController.serialUploadActive
                                 && (root.pcTarget
                                     ? (volumeCombo.count > 0 && root.selectedVolumeCompatible)
                                     : (appController.boardOnline && appController.boardSdReady))
                        ToolTip.visible: hovered && !root.pcTarget
                        ToolTip.text: "板载上传支持曲目0~14。目标文件不存在时由FPGA自动分配FAT32簇并创建RAW文件；电脑读卡器模式同样可以直接创建、覆盖和删除。"
                        onClicked: {
                            if (root.pcTarget)
                                appController.buildPackage(trackBox.value, volumeCombo.currentValue)
                            else
                                appController.buildPackageToBoard(trackBox.value)
                        }
                    }
                }
            }

            GlassPanel {
                Layout.fillWidth: true
                Layout.preferredHeight: 320
                Layout.minimumHeight: 320
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 22
                    spacing: 10
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "LCD1602 两行歌词预览"; color: root.textPrimary; font.pixelSize: 14; font.bold: true }
                        Item { Layout.fillWidth: true }
                        Text { text: appController.boardPreview.length + " PAGES"; color: root.cyan; font.pixelSize: 10; font.bold: true }
                    }
                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        spacing: 5
                        model: appController.boardPreview
                        delegate: Rectangle {
                            required property int index
                            required property string modelData
                            width: ListView.view.width
                            height: 35
                            radius: 8
                            color: index % 2 ? "#0D1422" : "#111827"
                            Text { anchors.fill: parent; anchors.leftMargin: 12; verticalAlignment: Text.AlignVCenter; text: modelData; color: "#A8B4C9"; font.family: "Consolas"; font.pixelSize: 11 }
                        }
                    }
                }
            }
        }
    }
}
