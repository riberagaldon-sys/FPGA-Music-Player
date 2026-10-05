#pragma once

#include <QAudioBuffer>
#include <QAudioBufferOutput>
#include <QAudioDecoder>
#include <QAudioOutput>
#include <QFile>
#include <QMediaPlayer>
#include <QObject>
#include <QUrl>

class AudioConverter final : public QObject
{
    Q_OBJECT

public:
    explicit AudioConverter(QObject *parent = nullptr);
    ~AudioConverter() override;

    void start(const QUrl &source);
    void cancel();
    QString rawPath() const { return m_rawPath; }

signals:
    void progressChanged(double progress, const QString &stage);
    void finished(const QString &rawPath, qint64 durationMs, quint64 bytes);
    void failed(const QString &message);

private slots:
    void readDecoderBuffer();
    void decoderFinished();
    void decoderError(QAudioDecoder::Error error);

private:
    bool openTemporaryOutput(bool truncate);
    bool writeConvertedBuffer(const QAudioBuffer &buffer);
    void startPlayerFallback();
    void finishConversion();
    void fail(const QString &message);
    void removeTemporaryRaw();

    QAudioDecoder m_decoder;
    QMediaPlayer m_fallbackPlayer;
    QAudioBufferOutput m_fallbackBufferOutput;
    QAudioOutput m_silentAudioOutput;
    QFile m_output;
    QString m_rawPath;
    QUrl m_source;
    qint64 m_durationMs = -1;
    quint64 m_bytesWritten = 0;
    bool m_running = false;
    bool m_usingPlayerFallback = false;
};
