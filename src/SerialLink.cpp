#include "SerialLink.h"

#include "SongPackage.h"

#include <QFileInfo>
#include <QSerialPortInfo>
#include <QtEndian>
#include <algorithm>

namespace {
constexpr char kSync0 = char(0xa5);
constexpr char kSync1 = char(0x5a);
constexpr quint8 kProtocolVersion = 1;
constexpr int kChunkBytes = 4096;
constexpr quint8 kAck = 0x80;
constexpr quint8 kStatus = 0x81;
constexpr quint8 kLog = 0x82;
constexpr quint8 kHelloReply = 0x83;
constexpr quint8 kSlotInfo = 0x84;

QString boardTrackFileName(int track)
{
    switch (track) {
    case 0: return QStringLiteral("SONG.RAW");
    case 1: return QStringLiteral("BEAUTY.RAW");
    case 2: return QStringLiteral("DIE4YOU.RAW");
    case 3: return QStringLiteral("PAYPHONE.RAW");
    case 4: return QStringLiteral("STARBOY.RAW");
    default:
        if (track >= 5 && track <= 14)
            return QStringLiteral("USR%1.RAW")
                .arg(track - 5, 2, 10, QLatin1Char('0'));
        return QStringLiteral("UNKNOWN");
    }
}

QString boardBuiltinTrackTitle(int track)
{
    switch (track) {
    case 0: return QStringLiteral("We Don't Talk Anymore");
    case 1: return QStringLiteral("Beauty And A Beat");
    case 2: return QStringLiteral("Die For You");
    case 3: return QStringLiteral("Payphone");
    case 4: return QStringLiteral("Starboy");
    default: return {};
    }
}
}

SerialLink::SerialLink(QObject *parent)
    : QObject(parent)
{
    m_ackTimer.setSingleShot(true);
    // Normal upload chunks should finish quickly, but board-side FAT32 file
    // creation and the final full-file CRC readback can legitimately take much
    // longer.  uploadPackage()/sendNextUploadChunk() select longer phase-specific
    // timeouts where required.
    m_ackTimer.setInterval(15000);
    connect(&m_ackTimer, &QTimer::timeout, this, &SerialLink::ackTimeout);

    m_slotQueryTimer.setSingleShot(true);
    m_slotQueryTimer.setInterval(5000);
    connect(&m_slotQueryTimer, &QTimer::timeout,
            this, &SerialLink::slotQueryTimeout);

    // Some FPGA revisions only answer QUERY_STATUS and do not push status
    // periodically.  Polling keeps play time, lyrics, TF-card state and controls
    // moving even with those revisions.  Do not poll during a file upload so
    // status frames cannot delay the per-block ACK transaction.
    m_statusTimer.setInterval(250);
    connect(&m_statusTimer, &QTimer::timeout, this, [this] {
        if (m_port.isOpen() && m_boardOnline && !uploadActive()
            && !m_slotScanActive && m_port.bytesToWrite() < 8192)
            sendCommand(QueryStatus);
    });

    // A lost first HELLO previously left the UI at "waiting for FPGA" forever.
    m_handshakeTimer.setInterval(700);
    connect(&m_handshakeTimer, &QTimer::timeout, this, [this] {
        if (m_port.isOpen() && !m_boardOnline)
            sendCommand(Hello, QByteArray("GXQT", 4));
    });
    connect(&m_port, &QSerialPort::readyRead,
            this, &SerialLink::readAvailable);
    connect(&m_port, &QSerialPort::errorOccurred,
            this, &SerialLink::serialError);
}

bool SerialLink::openPort(const QString &name, qint32 baudRate)
{
    closePort();
    m_port.setPortName(name);
    m_port.setBaudRate(baudRate);
    m_port.setDataBits(QSerialPort::Data8);
    m_port.setParity(QSerialPort::NoParity);
    m_port.setStopBits(QSerialPort::OneStop);
    m_port.setFlowControl(QSerialPort::NoFlowControl);
    if (!m_port.open(QIODevice::ReadWrite)) {
        setStatus(QStringLiteral("串口打开失败：%1").arg(m_port.errorString()));
        emit errorOccurred(m_status);
        emit openChanged();
        return false;
    }
    m_port.clear();
    setStatus(QStringLiteral("串口已打开，正在等待FPGA握手…"));
    emit openChanged();
    sendCommand(Hello, QByteArray("GXQT", 4));
    m_handshakeTimer.start();
    return true;
}

void SerialLink::closePort()
{
    const bool interruptedUpload = uploadActive();
    cancelUpload();
    m_ackTimer.stop();
    m_statusTimer.stop();
    m_handshakeTimer.stop();
    stopSlotScan();
    if (m_port.isOpen())
        m_port.close();
    m_receiveBuffer.clear();
    if (m_boardOnline) {
        m_boardOnline = false;
        emit boardOnlineChanged();
    }
    setStatus(QStringLiteral("未连接"));
    emit openChanged();
    if (interruptedUpload)
        emit uploadFailed(QStringLiteral("串口已断开，板载TF卡上传被中止。"));
}

void SerialLink::sendCommand(Command command, const QByteArray &payload)
{
    if (!m_port.isOpen()) {
        emit errorOccurred(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    if (command != Hello && !m_boardOnline) {
        emit errorOccurred(QStringLiteral("串口已打开，但FPGA尚未完成握手。"));
        return;
    }
    writeFrame(static_cast<quint8>(command), payload, false);
}

void SerialLink::uploadPackage(const QString &path, int slot,
                               quint64 verifiedBytes,
                               quint32 verifiedCrc32)
{
    const auto reject = [this](const QString &message) {
        setStatus(message);
        emit uploadFailed(message);
        emit errorOccurred(message);
    };
    if (!m_port.isOpen() || !m_boardOnline) {
        reject(QStringLiteral("FPGA尚未完成串口协议握手。"));
        return;
    }
    if (uploadActive()) {
        emit errorOccurred(QStringLiteral("已有歌曲正在上传。"));
        return;
    }
    stopSlotScan();
    // Recompute size + CRC32 from the exact file that is about to be opened.
    // Do not trust cached worker metadata here: the RAW may have been rebuilt or
    // replaced between generation and upload, which would make the board verify
    // perfectly written data against an old CRC and falsely report 0x0F.
    Q_UNUSED(verifiedBytes);
    Q_UNUSED(verifiedCrc32);
    const PackageResult check = SongPackage::verify(path);
    if (!check.ok) {
        reject(check.error);
        return;
    }
    const quint64 packageBytes = check.fileBytes;
    const quint32 packageCrc32 = check.fileCrc32;
    if (packageBytes > 0xffff'ffffULL) {
        reject(QStringLiteral("RAW文件超过串口协议4GiB上限。"));
        return;
    }
    m_uploadFile.setFileName(path);
    if (!m_uploadFile.open(QIODevice::ReadOnly)) {
        reject(QStringLiteral("无法打开待上传RAW文件。"));
        return;
    }

    m_uploadSize = static_cast<quint32>(m_uploadFile.size());
    m_uploadCrc = packageCrc32;
    m_uploadOffset = 0;
    m_pendingNextOffset = 0;
    m_uploadSlot = static_cast<quint8>(qBound(0, slot, 14));
    m_uploadProgress = 0.0;
    m_uploadPhase = UploadBeginWait;
    emit uploadProgressChanged();
    emit uploadActiveChanged();
    emit uploadStarted(m_uploadSlot, m_uploadSize);

    QByteArray payload;
    payload.append(char(m_uploadSlot));
    append32(payload, m_uploadSize);
    append32(payload, m_uploadCrc);
    // Creating USRxx.RAW directly on a large FAT32 TF card may require scanning
    // a sizeable FAT before the first ACK. Do not treat that work as a lost
    // serial packet.
    m_ackTimer.setInterval(90000);
    if (!writeFrame(BeginUpload, payload, true))
        return;
    setStatus(QStringLiteral("正在准备板载TF卡歌曲槽%1…").arg(m_uploadSlot));
}

void SerialLink::clearSlot(int slot)
{
    if (!m_port.isOpen() || !m_boardOnline) {
        emit errorOccurred(QStringLiteral("FPGA尚未完成串口协议握手。"));
        return;
    }
    if (uploadActive()) {
        emit errorOccurred(QStringLiteral("板载TF卡正在执行其他写入任务。"));
        return;
    }
    stopSlotScan();

    m_uploadSlot = static_cast<quint8>(qBound(0, slot, 14));
    m_uploadProgress = 0.0;
    m_uploadPhase = ClearWait;
    emit uploadProgressChanged();
    emit uploadActiveChanged();

    QByteArray payload;
    payload.append(char(m_uploadSlot));
    if (!writeFrame(ClearSlot, payload, true)) {
        m_uploadPhase = UploadIdle;
        emit uploadActiveChanged();
        return;
    }
    setStatus(QStringLiteral("正在删除/清空板载TF卡曲目%1（%2）…")
                  .arg(int(m_uploadSlot))
                  .arg(boardTrackFileName(int(m_uploadSlot))));
}

void SerialLink::querySlots()
{
    if (!m_port.isOpen() || !m_boardOnline) {
        emit errorOccurred(QStringLiteral("FPGA尚未完成串口协议握手。"));
        return;
    }
    if (uploadActive()) {
        emit errorOccurred(QStringLiteral("板载TF卡正在写入，完成后再刷新目录。"));
        return;
    }
    stopSlotScan();
    m_slotScanActive = true;
    m_slotQueryNext = 0;
    m_slotQueryRetry = 0;
    emit slotScanStarted();
    sendNextSlotQuery();
}

void SerialLink::sendNextSlotQuery()
{
    if (!m_slotScanActive)
        return;
    if (m_slotQueryNext > 14) {
        stopSlotScan();
        return;
    }
    // QuerySlot now carries the real board track number (0..14).
    // Tracks 0..14 are RAW songs; 5..14 use USRxx.RAW.
    QByteArray payload(1, char(m_slotQueryNext));
    if (!writeFrame(QuerySlot, payload, false)) {
        const int track = m_slotQueryNext;
        QVariantMap info;
        info.insert(QStringLiteral("slot"), track >= 5 ? track - 5 : -1);
        info.insert(QStringLiteral("track"), track);
        info.insert(QStringLiteral("builtin"), track < 5);
        info.insert(QStringLiteral("fileName"), boardTrackFileName(track));
        info.insert(QStringLiteral("present"), false);
        info.insert(QStringLiteral("valid"), false);
        info.insert(QStringLiteral("error"), 0xff);
        info.insert(QStringLiteral("fileSize"), 0);
        info.insert(QStringLiteral("title"), QStringLiteral("查询发送失败"));
        emit slotInfoReceived(info);
        ++m_slotQueryNext;
        QTimer::singleShot(0, this, &SerialLink::sendNextSlotQuery);
        return;
    }
    m_slotQueryTimer.start();
    setStatus(QStringLiteral("正在读取板载TF卡目录：%1/15…")
                  .arg(m_slotQueryNext + 1));
}

void SerialLink::stopSlotScan()
{
    const bool wasActive = m_slotScanActive;
    m_slotQueryTimer.stop();
    m_slotScanActive = false;
    if (wasActive)
        emit slotScanFinished();
}

void SerialLink::slotQueryTimeout()
{
    if (!m_slotScanActive)
        return;

    // A directory query temporarily takes ownership of the same TF-card SPI
    // engine used by audio playback.  On a busy card the first ownership
    // hand-off can occasionally miss the response window.  Retry the same
    // track before declaring it missing; otherwise one transient hand-off
    // makes the whole 15-track directory look empty.
    if (m_slotQueryRetry < 2) {
        ++m_slotQueryRetry;
        setStatus(QStringLiteral("TF卡目录查询重试：曲目%1（%2/3）…")
                      .arg(m_slotQueryNext)
                      .arg(m_slotQueryRetry + 1));
        QTimer::singleShot(120, this, &SerialLink::sendNextSlotQuery);
        return;
    }

    const int track = m_slotQueryNext;
    QVariantMap info;
    info.insert(QStringLiteral("slot"), track >= 5 ? track - 5 : -1);
    info.insert(QStringLiteral("track"), track);
    info.insert(QStringLiteral("builtin"), track < 5);
    info.insert(QStringLiteral("fileName"), boardTrackFileName(track));
    info.insert(QStringLiteral("present"), false);
    info.insert(QStringLiteral("valid"), false);
    info.insert(QStringLiteral("error"), 0xfe);
    info.insert(QStringLiteral("fileSize"), 0);
    info.insert(QStringLiteral("title"), QStringLiteral("查询超时（已重试3次）"));
    emit slotInfoReceived(info);
    ++m_slotQueryNext;
    m_slotQueryRetry = 0;
    QTimer::singleShot(120, this, &SerialLink::sendNextSlotQuery);
}

void SerialLink::cancelUpload()
{
    if (m_uploadPhase == UploadIdle)
        return;
    m_ackTimer.stop();
    m_ackTimer.setInterval(15000);
    m_uploadFile.close();
    m_uploadPhase = UploadIdle;
    m_uploadProgress = 0.0;
    setStatus(QStringLiteral("板载TF卡任务已取消"));
    emit uploadProgressChanged();
    emit uploadActiveChanged();
}

QByteArray SerialLink::frame(quint8 type, quint16 sequence,
                             const QByteArray &payload) const
{
    QByteArray output;
    output.reserve(payload.size() + 10);
    output.append(kSync0);
    output.append(kSync1);
    output.append(char(kProtocolVersion));
    output.append(char(type));
    append16(output, sequence);
    append16(output, static_cast<quint16>(payload.size()));
    output.append(payload);
    append16(output, crc16(output.constData() + 2, output.size() - 2));
    return output;
}

bool SerialLink::writeFrame(quint8 type, const QByteArray &payload,
                            bool waitForAck)
{
    const quint16 sequence = m_sequence++;
    const QByteArray bytes = frame(type, sequence, payload);
    if (m_port.write(bytes) != bytes.size()) {
        const QString message = QStringLiteral("串口发送缓存写入失败。");
        if (waitForAck && uploadActive())
            finishUpload(false, message);
        else
            emit errorOccurred(message);
        return false;
    }
    if (waitForAck) {
        m_waitingSequence = sequence;
        m_lastFrame = bytes;
        m_retryCount = 0;
        m_ackTimer.start();
    }
    return true;
}

void SerialLink::readAvailable()
{
    m_receiveBuffer.append(m_port.readAll());
    processFrames();
}

void SerialLink::processFrames()
{
    while (true) {
        QByteArray syncBytes;
        syncBytes.append(kSync0);
        syncBytes.append(kSync1);
        const int sync = m_receiveBuffer.indexOf(syncBytes);
        if (sync < 0) {
            if (m_receiveBuffer.size() > 1)
                m_receiveBuffer = m_receiveBuffer.right(1);
            return;
        }
        if (sync > 0)
            m_receiveBuffer.remove(0, sync);
        if (m_receiveBuffer.size() < 10)
            return;

        const quint16 payloadBytes = read16(m_receiveBuffer, 6);
        const int totalBytes = 10 + payloadBytes;
        if (payloadBytes > 8192) {
            m_receiveBuffer.remove(0, 2);
            continue;
        }
        if (m_receiveBuffer.size() < totalBytes)
            return;

        const quint16 receivedCrc = read16(m_receiveBuffer, 8 + payloadBytes);
        const quint16 calculatedCrc = crc16(m_receiveBuffer.constData() + 2,
                                            6 + payloadBytes);
        if (receivedCrc != calculatedCrc
            || quint8(m_receiveBuffer.at(2)) != kProtocolVersion) {
            m_receiveBuffer.remove(0, 2);
            continue;
        }

        const quint8 type = static_cast<quint8>(m_receiveBuffer.at(3));
        const quint16 sequence = read16(m_receiveBuffer, 4);
        const QByteArray payload = m_receiveBuffer.mid(8, payloadBytes);
        m_receiveBuffer.remove(0, totalBytes);
        processFrame(type, sequence, payload);
    }
}

void SerialLink::processFrame(quint8 type, quint16,
                              const QByteArray &payload)
{
    if (type == kAck) {
        processAck(payload);
    } else if (type == kHelloReply) {
        if (!m_boardOnline) {
            m_boardOnline = true;
            emit boardOnlineChanged();
        }
        m_handshakeTimer.stop();
        if (!m_statusTimer.isActive())
            m_statusTimer.start();
        setStatus(QStringLiteral("GX FPGA 已连接"));
        sendCommand(QueryStatus);
    } else if (type == kStatus && payload.size() >= 9) {
        // A valid status frame is also sufficient proof that the board speaks
        // this protocol.  This supports firmware that omits HELLO_REPLY.
        const bool becameOnline = !m_boardOnline;
        if (!m_boardOnline) {
            m_boardOnline = true;
            emit boardOnlineChanged();
        }
        m_handshakeTimer.stop();
        if (!m_statusTimer.isActive())
            m_statusTimer.start();
        if (becameOnline)
            setStatus(QStringLiteral("GX FPGA 已连接（STATUS兼容握手）"));
        QVariantMap statusMap;
        statusMap.insert(QStringLiteral("source"), quint8(payload.at(0)));
        statusMap.insert(QStringLiteral("track"), quint8(payload.at(1)));
        statusMap.insert(QStringLiteral("state"), quint8(payload.at(2)));
        statusMap.insert(QStringLiteral("playMs"), read32(payload, 3));
        statusMap.insert(QStringLiteral("error"), quint8(payload.at(7)));
        statusMap.insert(QStringLiteral("fifoPercent"), quint8(payload.at(8)));
        const bool extendedStatus = payload.size() >= 14;
        statusMap.insert(QStringLiteral("statusBytes"), payload.size());
        statusMap.insert(QStringLiteral("extendedStatus"), extendedStatus);
        statusMap.insert(QStringLiteral("sdReadyKnown"), extendedStatus);
        statusMap.insert(QStringLiteral("externalSignalKnown"), extendedStatus);
        statusMap.insert(QStringLiteral("controlsKnown"), extendedStatus);
        statusMap.insert(QStringLiteral("levelsKnown"), extendedStatus);
        if (extendedStatus) {
            const quint8 flags = quint8(payload.at(9));
            statusMap.insert(QStringLiteral("sdReady"), bool(flags & 0x01));
            statusMap.insert(QStringLiteral("externalSignal"), bool(flags & 0x02));
            statusMap.insert(QStringLiteral("speakerEnabled"), bool(flags & 0x04));
            statusMap.insert(QStringLiteral("pcInputMode"), bool(flags & 0x08));
            statusMap.insert(QStringLiteral("qspiCopyActive"), bool(flags & 0x10));
            statusMap.insert(QStringLiteral("qspiCopyOk"), bool(flags & 0x20));
            statusMap.insert(QStringLiteral("qspiCopyFailed"), bool(flags & 0x40));
            statusMap.insert(QStringLiteral("leftLevel"), quint8(payload.at(10)));
            statusMap.insert(QStringLiteral("rightLevel"), quint8(payload.at(11)));
            statusMap.insert(QStringLiteral("volume"), quint8(payload.at(12)));
            statusMap.insert(QStringLiteral("tone"), quint8(payload.at(13)));
            if (payload.size() >= 26) {
                statusMap.insert(QStringLiteral("playMode"), quint8(payload.at(14)) & 0x03);
                const quint8 resumeFlags = quint8(payload.at(15));
                statusMap.insert(QStringLiteral("resumeValid"), bool(resumeFlags & 0x01));
                statusMap.insert(QStringLiteral("resumeBusy"), bool(resumeFlags & 0x02));
                statusMap.insert(QStringLiteral("resumeSaveOk"), bool(resumeFlags & 0x04));
                statusMap.insert(QStringLiteral("resumeSaveFailed"), bool(resumeFlags & 0x08));
                statusMap.insert(QStringLiteral("resumeTrack"), quint8(payload.at(16)));
                statusMap.insert(QStringLiteral("resumeSource"), quint8(payload.at(17)));
                statusMap.insert(QStringLiteral("resumeMs"), read32(payload, 18));
                statusMap.insert(QStringLiteral("totalMs"), read32(payload, 22));
            } else {
                statusMap.insert(QStringLiteral("playMode"), 0);
                statusMap.insert(QStringLiteral("resumeValid"), false);
                statusMap.insert(QStringLiteral("resumeBusy"), false);
                statusMap.insert(QStringLiteral("resumeSaveOk"), false);
                statusMap.insert(QStringLiteral("resumeSaveFailed"), false);
                statusMap.insert(QStringLiteral("resumeTrack"), 0);
                statusMap.insert(QStringLiteral("resumeSource"), 0);
                statusMap.insert(QStringLiteral("resumeMs"), 0);
                statusMap.insert(QStringLiteral("totalMs"), 0);
            }
        } else {
            // With the old 9-byte reply the board does not expose a separate
            // TF-ready flag.  A clean TF-source status is the strongest safe
            // indication available; mark it as inferred so the UI can say so.
            const int source = statusMap.value(QStringLiteral("source")).toInt();
            const int error = statusMap.value(QStringLiteral("error")).toInt();
            const bool inferredSdReady = source == 0 && error == 0;
            statusMap.insert(QStringLiteral("sdReady"), inferredSdReady);
            statusMap.insert(QStringLiteral("sdReadyInferred"), inferredSdReady);
            statusMap.insert(QStringLiteral("externalSignal"), false);
            statusMap.insert(QStringLiteral("speakerEnabled"), true);
            statusMap.insert(QStringLiteral("pcInputMode"), false);
            statusMap.insert(QStringLiteral("qspiCopyActive"), false);
            statusMap.insert(QStringLiteral("qspiCopyOk"), false);
            statusMap.insert(QStringLiteral("qspiCopyFailed"), false);
            statusMap.insert(QStringLiteral("leftLevel"), 0);
            statusMap.insert(QStringLiteral("rightLevel"), 0);
            statusMap.insert(QStringLiteral("volume"), 100);
            statusMap.insert(QStringLiteral("tone"), 50);
            statusMap.insert(QStringLiteral("playMode"), 0);
            statusMap.insert(QStringLiteral("resumeValid"), false);
            statusMap.insert(QStringLiteral("resumeBusy"), false);
            statusMap.insert(QStringLiteral("resumeSaveOk"), false);
            statusMap.insert(QStringLiteral("resumeSaveFailed"), false);
            statusMap.insert(QStringLiteral("resumeTrack"), 0);
            statusMap.insert(QStringLiteral("resumeSource"), 0);
            statusMap.insert(QStringLiteral("resumeMs"), 0);
            statusMap.insert(QStringLiteral("totalMs"), 0);
        }
        emit boardStatusReceived(statusMap);
    } else if (type == kSlotInfo && payload.size() >= 23) {
        const int track = quint8(payload.at(0));
        if (track < 0 || track > 14)
            return;
        const int slot = track >= 5 ? track - 5 : -1;
        const bool builtin = track < 5;
        const quint8 flags = quint8(payload.at(1));
        const int error = quint8(payload.at(2));
        QByteArray reversedTitle = payload.mid(3, 16);
        std::reverse(reversedTitle.begin(), reversedTitle.end());
        while (!reversedTitle.isEmpty()
               && (reversedTitle.endsWith(' ') || reversedTitle.endsWith('\0')))
            reversedTitle.chop(1);
        QString title = QString::fromLatin1(reversedTitle).trimmed();
        const bool present = flags & 0x01;
        const bool valid = flags & 0x02;
        if (error == 0x0b) {
            title = QStringLiteral("TF卡目录查询超时（已重试3次）");
        } else if (builtin) {
            // RAW files have no GXM metadata header, so use the fixed title
            // only after the FPGA has actually found the corresponding file.
            title = present ? boardBuiltinTrackTitle(track)
                            : QStringLiteral("内置RAW文件缺失");
        } else if (title.isEmpty()) {
            title = !present ? QStringLiteral("未创建槽位")
                             : valid ? QStringLiteral("USER SONG")
                                     : QStringLiteral("空RAW槽 / 文件无效");
        }
        // Firmware returns 0x0B when the shared TF-card SPI ownership
        // hand-off did not settle before its watchdog expired.  Retry the same
        // track instead of immediately showing it as missing.
        if (m_slotScanActive && track == m_slotQueryNext && error == 0x0b) {
            m_slotQueryTimer.stop();
            if (m_slotQueryRetry < 2) {
                ++m_slotQueryRetry;
                setStatus(QStringLiteral("TF卡目录查询重试：曲目%1（%2/3）…")
                              .arg(track)
                              .arg(m_slotQueryRetry + 1));
                QTimer::singleShot(150, this, &SerialLink::sendNextSlotQuery);
                return;
            }
        }

        QVariantMap info;
        info.insert(QStringLiteral("slot"), slot);
        info.insert(QStringLiteral("track"), track);
        info.insert(QStringLiteral("builtin"), builtin);
        info.insert(QStringLiteral("fileName"), boardTrackFileName(track));
        info.insert(QStringLiteral("present"), present);
        info.insert(QStringLiteral("valid"), valid);
        info.insert(QStringLiteral("error"), error);
        info.insert(QStringLiteral("title"), title);
        info.insert(QStringLiteral("fileSize"), read32(payload, 19));
        emit slotInfoReceived(info);

        if (m_slotScanActive && track == m_slotQueryNext) {
            m_slotQueryTimer.stop();
            ++m_slotQueryNext;
            m_slotQueryRetry = 0;
            QTimer::singleShot(80, this, &SerialLink::sendNextSlotQuery);
        }
    } else if (type == kLog) {
        emit messageReceived(QString::fromUtf8(payload));
    }
}

void SerialLink::processAck(const QByteArray &payload)
{
    if (payload.size() < 3)
        return;
    // Firmware only acknowledges the three upload packet types.  Ignore an
    // unsolicited/stale ACK once an upload has already been cancelled.
    if (m_uploadPhase == UploadIdle)
        return;
    const quint16 acknowledged = read16(payload, 0);
    if (acknowledged != m_waitingSequence)
        return;
    m_ackTimer.stop();
    const quint8 result = static_cast<quint8>(payload.at(2));
    if (result != 0) {
        if (m_uploadPhase == ClearWait) {
            finishUpload(false,
                         QStringLiteral("曲目%1（%2）删除/清空失败：板端错误码0x%3")
                             .arg(int(m_uploadSlot))
                             .arg(boardTrackFileName(int(m_uploadSlot)))
                             .arg(result, 2, 16, QLatin1Char('0')));
        } else {
            QString message = uploadErrorMessage(result);
            // New firmware appends expected/actual CRC32 to 0x0F and 0x10 ACKs:
            // bytes 3..6 expected (LE), bytes 7..10 actual (LE).  Showing both
            // values makes a real TF-card corruption distinguishable from a
            // stale/wrong CRC sent by the PC.
            if ((result == 0x0F || result == 0x10) && payload.size() >= 11) {
                const quint32 expected = read32(payload, 3);
                const quint32 actual = read32(payload, 7);
                message += QStringLiteral("；期望CRC32=0x%1，板端CRC32=0x%2")
                               .arg(expected, 8, 16, QLatin1Char('0'))
                               .arg(actual, 8, 16, QLatin1Char('0'));
            }
            finishUpload(false, message);
        }
        return;
    }

    if (m_uploadPhase == UploadBeginWait) {
        m_ackTimer.setInterval(15000);
        m_uploadPhase = UploadDataWait;
        sendNextUploadChunk();
    } else if (m_uploadPhase == UploadDataWait) {
        m_uploadOffset = m_pendingNextOffset;
        m_uploadProgress = m_uploadSize == 0
            ? 0.0 : double(m_uploadOffset) / double(m_uploadSize);
        emit uploadProgressChanged();
        sendNextUploadChunk();
    } else if (m_uploadPhase == UploadEndWait) {
        finishUpload(true, QStringLiteral("板载TF卡写入及CRC校验完成。"));
    } else if (m_uploadPhase == ClearWait) {
        m_ackTimer.stop();
        m_uploadFile.close();
        m_uploadPhase = UploadIdle;
        m_uploadProgress = 1.0;
        setStatus(QStringLiteral("板载TF卡曲目已删除/清空。"));
        emit uploadProgressChanged();
        emit uploadActiveChanged();
        emit slotCleared(int(m_uploadSlot));
        sendCommand(ReloadMedia);
    }
}

void SerialLink::sendNextUploadChunk()
{
    if (m_uploadOffset >= m_uploadSize) {
        QByteArray payload;
        payload.append(char(m_uploadSlot));
        append32(payload, m_uploadSize);
        append32(payload, m_uploadCrc);
        m_uploadPhase = UploadEndWait;
        // FPGA now reads the whole RAW file back from TF card and compares CRC32
        // before committing the directory file size. Allow enough time for a
        // full song on slower cards.
        m_ackTimer.setInterval(180000);
        if (!writeFrame(EndUpload, payload, true))
            return;
        setStatus(QStringLiteral("正在让FPGA回读整首RAW并校验CRC…"));
        return;
    }

    if (!m_uploadFile.seek(m_uploadOffset)) {
        finishUpload(false, QStringLiteral("无法定位本地RAW文件。"));
        return;
    }
    const QByteArray data = m_uploadFile.read(kChunkBytes);
    if (data.isEmpty()) {
        finishUpload(false, QStringLiteral("读取本地RAW文件失败。"));
        return;
    }
    QByteArray payload;
    payload.reserve(data.size() + 4);
    append32(payload, m_uploadOffset);
    payload.append(data);
    m_pendingNextOffset = m_uploadOffset + static_cast<quint32>(data.size());
    if (!writeFrame(UploadData, payload, true))
        return;
    setStatus(QStringLiteral("正在通过串口上传：%1%")
                  .arg(int(m_uploadProgress * 100.0)));
}

void SerialLink::finishUpload(bool success, const QString &message)
{
    m_ackTimer.stop();
    m_ackTimer.setInterval(15000);
    m_uploadFile.close();
    m_uploadPhase = UploadIdle;
    m_uploadProgress = success ? 1.0 : 0.0;
    setStatus(message);
    emit uploadProgressChanged();
    emit uploadActiveChanged();
    if (success) {
        emit uploadFinished();
        sendCommand(ReloadMedia);
    } else {
        emit uploadFailed(message);
        emit errorOccurred(message);
    }
}

QString SerialLink::uploadErrorMessage(quint8 result) const
{
    const QString target = QStringLiteral("曲目%1（%2）")
        .arg(int(m_uploadSlot))
        .arg(boardTrackFileName(int(m_uploadSlot)));
    QString reason;
    switch (result) {
    case 0x01:
        reason = QStringLiteral("上传请求格式或RAW文件大小不符合协议");
        break;
    case 0x02:
        reason = QStringLiteral("板端无法挂载TF卡或取得FAT32几何信息");
        break;
    case 0x03:
        reason = QStringLiteral("目标RAW文件不存在且板端没有取得可用根目录项");
        break;
    case 0x04:
        reason = QStringLiteral("上传偏移不连续，请重试");
        break;
    case 0x05:
        reason = QStringLiteral("TF卡写入链路失败（旧版固件兼容错误码）");
        break;
    case 0x06:
        reason = QStringLiteral("上传结束帧的曲目/长度/偏移校验失败");
        break;
    case 0x07:
        reason = QStringLiteral("板端当前正占用TF卡/QSFLASH，暂不允许上传");
        break;
    case 0x08:
        reason = QStringLiteral("TF卡底层CMD24写入失败；请检查卡接触、供电或重新插卡");
        break;
    case 0x09:
        reason = QStringLiteral("旧版逐扇区回读校验失败；请确认已烧录新版整文件CRC固件");
        break;
    case 0x0A:
        reason = QStringLiteral("RAW文件FAT32簇链提前结束或损坏");
        break;
    case 0x0B:
        reason = QStringLiteral("RAW文件长度目录项提交后回读校验失败");
        break;
    case 0x0C:
        reason = QStringLiteral("TF卡没有找到足够的连续空闲簇用于创建RAW文件");
        break;
    case 0x0D:
        reason = QStringLiteral("板端创建RAW文件时写FAT1/FAT2失败");
        break;
    case 0x0E:
        reason = QStringLiteral("板端创建RAW文件根目录项失败");
        break;
    case 0x0F:
        reason = QStringLiteral("RAW写入完成，但整首文件从TF卡回读后的CRC32与电脑原文件不一致");
        break;
    case 0x10:
        reason = QStringLiteral("FPGA收到的整首RAW数据CRC32与电脑原文件不一致（TF卡写入前即已不一致）");
        break;
    default:
        reason = QStringLiteral("板端返回未知错误");
        break;
    }
    return QStringLiteral("%1 上传失败：%2（错误码0x%3）")
        .arg(target, reason)
        .arg(result, 2, 16, QLatin1Char('0'));
}

void SerialLink::serialError(QSerialPort::SerialPortError error)
{
    if (error == QSerialPort::NoError || error == QSerialPort::TimeoutError)
        return;
    const QString message = QStringLiteral("串口错误：%1").arg(m_port.errorString());
    emit errorOccurred(message);
    if (error == QSerialPort::ResourceError
        || error == QSerialPort::DeviceNotFoundError)
        closePort();
}

void SerialLink::ackTimeout()
{
    if (m_uploadPhase == UploadIdle)
        return;

    // BEGIN can be busy allocating FAT clusters and END can be busy reading the
    // whole file back. Re-sending those commands while the FPGA is still inside
    // the operation creates duplicate requests and makes recovery harder.
    if (m_uploadPhase == UploadBeginWait) {
        finishUpload(false, QStringLiteral(
            "FPGA创建/定位RAW文件超过90秒，请刷新TF卡目录后重试。"));
        return;
    }
    if (m_uploadPhase == UploadEndWait) {
        finishUpload(false, QStringLiteral(
            "FPGA整首RAW回读CRC校验超过180秒，请刷新目录确认文件状态。"));
        return;
    }

    if (++m_retryCount > 3) {
        finishUpload(false, QStringLiteral("FPGA数据块响应超时，已重试3次。"));
        return;
    }
    if (m_port.write(m_lastFrame) != m_lastFrame.size()) {
        finishUpload(false, QStringLiteral("串口重传写入失败。"));
        return;
    }
    m_ackTimer.start();
    setStatus(QStringLiteral("数据块超时，正在重传 %1/3…").arg(m_retryCount));
}

void SerialLink::setStatus(const QString &status)
{
    if (m_status == status)
        return;
    m_status = status;
    emit statusChanged();
}

quint16 SerialLink::crc16(const char *data, qsizetype size)
{
    quint16 crc = 0xffff;
    for (qsizetype index = 0; index < size; ++index) {
        crc ^= quint16(static_cast<quint8>(data[index])) << 8;
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc & 0x8000) ? quint16((crc << 1) ^ 0x1021)
                                 : quint16(crc << 1);
    }
    return crc;
}

void SerialLink::append16(QByteArray &data, quint16 value)
{
    char bytes[2];
    qToLittleEndian(value, reinterpret_cast<uchar *>(bytes));
    data.append(bytes, 2);
}

void SerialLink::append32(QByteArray &data, quint32 value)
{
    char bytes[4];
    qToLittleEndian(value, reinterpret_cast<uchar *>(bytes));
    data.append(bytes, 4);
}

quint16 SerialLink::read16(const QByteArray &data, int offset)
{
    return qFromLittleEndian<quint16>(
        reinterpret_cast<const uchar *>(data.constData() + offset));
}

quint32 SerialLink::read32(const QByteArray &data, int offset)
{
    return qFromLittleEndian<quint32>(
        reinterpret_cast<const uchar *>(data.constData() + offset));
}
