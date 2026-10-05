#include "AudioConverter.h"

#include <QAudioFormat>
#include <QDir>
#include <QStandardPaths>
#include <QSysInfo>
#include <QUuid>

#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
float sampleAsFloat(const char *ptr, QAudioFormat::SampleFormat format)
{
    switch (format) {
    case QAudioFormat::UInt8:
        return (static_cast<unsigned char>(*ptr) - 128.0f) / 128.0f;
    case QAudioFormat::Int16: {
        qint16 value = 0;
        std::memcpy(&value, ptr, sizeof(value));
        return std::max(-1.0f, float(value) / 32768.0f);
    }
    case QAudioFormat::Int32: {
        qint32 value = 0;
        std::memcpy(&value, ptr, sizeof(value));
        return std::max(-1.0f, float(double(value) / 2147483648.0));
    }
    case QAudioFormat::Float: {
        float value = 0.0f;
        std::memcpy(&value, ptr, sizeof(value));
        return std::clamp(value, -1.0f, 1.0f);
    }
    default:
        return 0.0f;
    }
}

qint16 floatToInt16(float value)
{
    const float limited = std::clamp(value, -1.0f, 1.0f);
    if (limited <= -1.0f)
        return -32768;
    return static_cast<qint16>(std::lround(limited * 32767.0f));
}
}

AudioConverter::AudioConverter(QObject *parent)
    : QObject(parent),
      m_decoder(this),
      m_fallbackPlayer(this),
      m_fallbackBufferOutput(this),
      m_silentAudioOutput(this)
{
    connect(&m_decoder, &QAudioDecoder::bufferReady,
            this, &AudioConverter::readDecoderBuffer);
    connect(&m_decoder, &QAudioDecoder::finished,
            this, &AudioConverter::decoderFinished);
    connect(&m_decoder, &QAudioDecoder::durationChanged,
            this, [this](qint64 duration) {
                if (!m_usingPlayerFallback)
                    m_durationMs = duration;
            });
    connect(&m_decoder, &QAudioDecoder::positionChanged,
            this, [this](qint64 position) {
                if (!m_running || m_usingPlayerFallback)
                    return;
                const double ratio = m_durationMs > 0
                    ? qBound(0.0, double(position) / double(m_durationMs), 1.0)
                    : 0.0;
                emit progressChanged(ratio * 0.78,
                                     QStringLiteral("正在将MP3解码为板载PCM…"));
            });
    connect(&m_decoder,
            static_cast<void (QAudioDecoder::*)(QAudioDecoder::Error)>(
                &QAudioDecoder::error),
            this, &AudioConverter::decoderError);

    // Qt 6.11 on some Windows installations can play an MP3 with QMediaPlayer
    // while QAudioDecoder returns FINISHED without a single PCM buffer.  Use
    // the exact same multimedia playback backend as a compatibility decoder.
    m_silentAudioOutput.setVolume(0.0);
    m_fallbackPlayer.setAudioOutput(&m_silentAudioOutput);
    m_fallbackPlayer.setAudioBufferOutput(&m_fallbackBufferOutput);

    connect(&m_fallbackBufferOutput, &QAudioBufferOutput::audioBufferReceived,
            this, [this](const QAudioBuffer &buffer) {
                if (m_running && m_usingPlayerFallback && buffer.isValid())
                    writeConvertedBuffer(buffer);
            });
    connect(&m_fallbackPlayer, &QMediaPlayer::durationChanged,
            this, [this](qint64 duration) {
                if (m_usingPlayerFallback)
                    m_durationMs = duration;
            });
    connect(&m_fallbackPlayer, &QMediaPlayer::positionChanged,
            this, [this](qint64 position) {
                if (!m_running || !m_usingPlayerFallback)
                    return;
                const double ratio = m_durationMs > 0
                    ? qBound(0.0, double(position) / double(m_durationMs), 1.0)
                    : 0.0;
                emit progressChanged(ratio * 0.78,
                    QStringLiteral("QMediaPlayer兼容解码中…"));
            });
    connect(&m_fallbackPlayer, &QMediaPlayer::mediaStatusChanged,
            this, [this](QMediaPlayer::MediaStatus status) {
                if (!m_running || !m_usingPlayerFallback)
                    return;
                if (status == QMediaPlayer::EndOfMedia) {
                    finishConversion();
                } else if (status == QMediaPlayer::InvalidMedia) {
                    fail(QStringLiteral("MP3兼容解码失败：文件无法由Qt Multimedia读取。"));
                }
            });
    connect(&m_fallbackPlayer, &QMediaPlayer::errorOccurred,
            this, [this](QMediaPlayer::Error error, const QString &errorString) {
                if (!m_running || !m_usingPlayerFallback
                    || error == QMediaPlayer::NoError)
                    return;
                fail(QStringLiteral("MP3兼容解码失败：%1").arg(errorString));
            });
}

AudioConverter::~AudioConverter()
{
    cancel();
    removeTemporaryRaw();
}

bool AudioConverter::openTemporaryOutput(bool truncate)
{
    if (m_output.isOpen())
        m_output.close();
    m_output.setFileName(m_rawPath);
    QIODevice::OpenMode mode = QIODevice::WriteOnly;
    if (truncate)
        mode |= QIODevice::Truncate;
    if (!m_output.open(mode)) {
        emit failed(QStringLiteral("无法创建临时PCM文件：%1")
                        .arg(m_output.errorString()));
        return false;
    }
    return true;
}

void AudioConverter::start(const QUrl &source)
{
    cancel();
    removeTemporaryRaw();

    if (!source.isLocalFile()) {
        emit failed(QStringLiteral("请选择电脑上的本地MP3文件。"));
        return;
    }

    m_source = source;
    QString tempRoot = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    if (tempRoot.isEmpty())
        tempRoot = QDir::tempPath();
    m_rawPath = QDir(tempRoot).filePath(
        QStringLiteral("gxmusic-%1.raw")
            .arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));

    if (!openTemporaryOutput(true))
        return;

    m_bytesWritten = 0;
    m_durationMs = -1;
    m_running = true;
    m_usingPlayerFallback = false;

    // Do not force QAudioDecoder's output format.  The Qt 6.11 FFmpeg backend
    // may otherwise report FINISHED with zero buffers for otherwise playable
    // MP3 files.  Native PCM is converted to 44.1 kHz / Int16 / stereo below.
    m_decoder.setSource(source);
    emit progressChanged(0.01, QStringLiteral("正在打开MP3…"));
    m_decoder.start();
}

void AudioConverter::cancel()
{
    if (!m_running && !m_usingPlayerFallback)
        return;
    m_running = false;
    m_usingPlayerFallback = false;
    m_decoder.stop();
    m_fallbackPlayer.stop();
    m_fallbackPlayer.setSource(QUrl());
    if (m_output.isOpen())
        m_output.close();
}

void AudioConverter::readDecoderBuffer()
{
    if (!m_running || m_usingPlayerFallback)
        return;
    const QAudioBuffer buffer = m_decoder.read();
    if (buffer.isValid())
        writeConvertedBuffer(buffer);
}

bool AudioConverter::writeConvertedBuffer(const QAudioBuffer &buffer)
{
    if (!buffer.isValid() || buffer.byteCount() <= 0)
        return true;

    const QAudioFormat format = buffer.format();
    const int sourceRate = format.sampleRate();
    const int channels = format.channelCount();
    const int bytesPerSample = format.bytesPerSample();
    if (sourceRate <= 0 || channels <= 0 || bytesPerSample <= 0
        || format.sampleFormat() == QAudioFormat::Unknown) {
        fail(QStringLiteral("MP3解码器返回了无法识别的PCM格式。"));
        return false;
    }

    const int bytesPerFrame = bytesPerSample * channels;
    const int sourceFrames = buffer.byteCount() / bytesPerFrame;
    if (sourceFrames <= 0)
        return true;

    const char *source = buffer.constData<char>();
    const qint64 outputFrames = std::max<qint64>(
        1, qRound64(double(sourceFrames) * 44100.0 / double(sourceRate)));
    QByteArray output;
    output.resize(static_cast<qsizetype>(outputFrames * 4));
    char *destination = output.data();

    const auto channelSample = [&](int frame, int channel) -> float {
        frame = qBound(0, frame, sourceFrames - 1);
        const int selectedChannel = channels == 1 ? 0 : qMin(channel, channels - 1);
        const char *ptr = source + frame * bytesPerFrame
                          + selectedChannel * bytesPerSample;
        return sampleAsFloat(ptr, format.sampleFormat());
    };

    for (qint64 outFrame = 0; outFrame < outputFrames; ++outFrame) {
        const double sourcePosition = double(outFrame) * double(sourceRate) / 44100.0;
        const int frame0 = qBound(0, int(std::floor(sourcePosition)), sourceFrames - 1);
        const int frame1 = qMin(frame0 + 1, sourceFrames - 1);
        const float fraction = float(sourcePosition - double(frame0));

        const float l0 = channelSample(frame0, 0);
        const float l1 = channelSample(frame1, 0);
        const float r0 = channels == 1 ? l0 : channelSample(frame0, 1);
        const float r1 = channels == 1 ? l1 : channelSample(frame1, 1);
        const qint16 left = floatToInt16(l0 + (l1 - l0) * fraction);
        const qint16 right = floatToInt16(r0 + (r1 - r0) * fraction);

        std::memcpy(destination + outFrame * 4, &left, sizeof(left));
        std::memcpy(destination + outFrame * 4 + 2, &right, sizeof(right));
    }

    if (QSysInfo::ByteOrder == QSysInfo::BigEndian) {
        for (qsizetype i = 0; i + 1 < output.size(); i += 2)
            std::swap(output[i], output[i + 1]);
    }

    if (m_output.write(output) != output.size()) {
        fail(QStringLiteral("写入临时PCM失败：%1").arg(m_output.errorString()));
        return false;
    }
    m_bytesWritten += static_cast<quint64>(output.size());
    return true;
}

void AudioConverter::decoderFinished()
{
    if (!m_running || m_usingPlayerFallback)
        return;

    if (m_bytesWritten == 0) {
        // This is the exact failure shown on some Qt 6.11 Windows builds.
        // Retry with QMediaPlayer + QAudioBufferOutput, which uses the same
        // backend that already succeeds on the application's playback page.
        startPlayerFallback();
        return;
    }
    finishConversion();
}

void AudioConverter::startPlayerFallback()
{
    m_decoder.stop();
    if (m_output.isOpen())
        m_output.close();

    m_bytesWritten = 0;
    m_durationMs = -1;
    if (!openTemporaryOutput(true)) {
        m_running = false;
        return;
    }

    m_usingPlayerFallback = true;
    emit progressChanged(0.02,
        QStringLiteral("QAudioDecoder未返回PCM，正在自动切换兼容解码…"));

    m_fallbackPlayer.stop();
    m_fallbackPlayer.setSource(QUrl());
    m_fallbackPlayer.setSource(m_source);
    // Four times speed keeps this fallback reasonably quick while avoiding
    // aggressive rates at which some Windows audio backends drop buffers.
    m_fallbackPlayer.setPlaybackRate(4.0);
    m_fallbackPlayer.play();
}

void AudioConverter::finishConversion()
{
    if (!m_running)
        return;

    m_fallbackPlayer.stop();
    m_usingPlayerFallback = false;
    m_running = false;
    if (m_output.isOpen())
        m_output.close();

    if (m_bytesWritten == 0) {
        fail(QStringLiteral(
            "MP3已经能被播放器打开，但两种Qt解码路径都没有返回PCM数据。"));
        return;
    }

    const qint64 exactDuration = static_cast<qint64>(
        (m_bytesWritten * 1000ULL) / (44'100ULL * 4ULL));
    emit progressChanged(0.78, QStringLiteral("PCM转换完成，正在生成歌曲包…"));
    emit finished(m_rawPath, exactDuration, m_bytesWritten);
}

void AudioConverter::decoderError(QAudioDecoder::Error error)
{
    if (!m_running || m_usingPlayerFallback || error == QAudioDecoder::NoError)
        return;

    // A decoder error is not fatal yet: QMediaPlayer may still decode the same
    // MP3, as already observed on the normal playback page.
    startPlayerFallback();
}

void AudioConverter::fail(const QString &message)
{
    m_running = false;
    m_usingPlayerFallback = false;
    m_decoder.stop();
    m_fallbackPlayer.stop();
    if (m_output.isOpen())
        m_output.close();
    emit failed(message);
}

void AudioConverter::removeTemporaryRaw()
{
    if (!m_rawPath.isEmpty())
        QFile::remove(m_rawPath);
    m_rawPath.clear();
}
