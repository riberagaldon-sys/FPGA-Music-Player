#pragma once

#include <QByteArray>
#include <QFile>
#include <QObject>
#include <QSerialPort>
#include <QTimer>
#include <QVariantMap>

class SerialLink final : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool open READ isOpen NOTIFY openChanged)
    Q_PROPERTY(bool boardOnline READ boardOnline NOTIFY boardOnlineChanged)
    Q_PROPERTY(QString portName READ portName NOTIFY openChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(double uploadProgress READ uploadProgress NOTIFY uploadProgressChanged)
    Q_PROPERTY(bool uploadActive READ uploadActive NOTIFY uploadActiveChanged)

public:
    enum Command : quint8 {
        Hello = 0x01,
        QueryStatus = 0x02,
        Play = 0x10,
        Pause = 0x11,
        Previous = 0x12,
        Next = 0x13,
        SelectSource = 0x14,
        SelectTrack = 0x15,
        SetVolume = 0x16,
        SetTone = 0x17,
        SetSpeaker = 0x18,
        CopySdDemoToQspi = 0x19,
        SetPlayMode = 0x1A,
        Seek = 0x1B,
        SaveResume = 0x1C,
        RestoreResume = 0x1D,
        BeginUpload = 0x20,
        UploadData = 0x21,
        EndUpload = 0x22,
        ReloadMedia = 0x23,
        SetBaud = 0x24,
        ClearSlot = 0x25,
        QuerySlot = 0x26,
        SetLcdLyricPage = 0x27,
        ClearLcdLyricPage = 0x28
    };
    Q_ENUM(Command)

    explicit SerialLink(QObject *parent = nullptr);

    bool isOpen() const { return m_port.isOpen(); }
    bool boardOnline() const { return m_boardOnline; }
    QString portName() const { return m_port.portName(); }
    QString status() const { return m_status; }
    double uploadProgress() const { return m_uploadProgress; }
    bool uploadActive() const { return m_uploadPhase != UploadIdle; }

    bool openPort(const QString &name, qint32 baudRate);
    void closePort();
    void sendCommand(Command command, const QByteArray &payload = {});
    void uploadPackage(const QString &path, int slot,
                       quint64 verifiedBytes = 0,
                       quint32 verifiedCrc32 = 0);
    void clearSlot(int slot);
    void querySlots();
    void cancelUpload();

signals:
    void openChanged();
    void boardOnlineChanged();
    void statusChanged();
    void uploadProgressChanged();
    void uploadActiveChanged();
    void uploadStarted(int slot, quint64 bytes);
    void boardStatusReceived(const QVariantMap &status);
    void messageReceived(const QString &message);
    void errorOccurred(const QString &message);
    void uploadFinished();
    void uploadFailed(const QString &message);
    void slotInfoReceived(const QVariantMap &info);
    void slotScanStarted();
    void slotScanFinished();
    void slotCleared(int slot);

private slots:
    void readAvailable();
    void serialError(QSerialPort::SerialPortError error);
    void ackTimeout();
    void slotQueryTimeout();

private:
    enum UploadPhase { UploadIdle, UploadBeginWait, UploadDataWait, UploadEndWait, ClearWait };

    QByteArray frame(quint8 type, quint16 sequence,
                     const QByteArray &payload) const;
    bool writeFrame(quint8 type, const QByteArray &payload, bool waitForAck);
    void processFrames();
    void processFrame(quint8 type, quint16 sequence, const QByteArray &payload);
    void processAck(const QByteArray &payload);
    void sendNextUploadChunk();
    void finishUpload(bool success, const QString &message);
    void sendNextSlotQuery();
    void stopSlotScan();
    QString uploadErrorMessage(quint8 result) const;
    void setStatus(const QString &status);
    static quint16 crc16(const char *data, qsizetype size);
    static void append16(QByteArray &data, quint16 value);
    static void append32(QByteArray &data, quint32 value);
    static quint16 read16(const QByteArray &data, int offset);
    static quint32 read32(const QByteArray &data, int offset);

    QSerialPort m_port;
    QByteArray m_receiveBuffer;
    QTimer m_ackTimer;
    QTimer m_statusTimer;
    QTimer m_handshakeTimer;
    QTimer m_slotQueryTimer;
    quint16 m_sequence = 1;
    quint16 m_waitingSequence = 0;
    QByteArray m_lastFrame;
    int m_retryCount = 0;
    bool m_boardOnline = false;
    QString m_status = QStringLiteral("未连接");

    QFile m_uploadFile;
    UploadPhase m_uploadPhase = UploadIdle;
    quint32 m_uploadSize = 0;
    quint32 m_uploadCrc = 0;
    quint32 m_uploadOffset = 0;
    quint32 m_pendingNextOffset = 0;
    quint8 m_uploadSlot = 0;
    double m_uploadProgress = 0.0;
    bool m_slotScanActive = false;
    int m_slotQueryNext = 0;
    int m_slotQueryRetry = 0;
};
