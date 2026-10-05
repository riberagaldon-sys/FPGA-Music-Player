#include "AppController.h"

#include <QDir>
#include <QAudioDevice>
#include <QCoreApplication>
#include <QDateTime>
#include <QFileInfo>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMediaMetaData>
#include <QMediaDevices>
#include <QPointer>
#include <QRegularExpression>
#include <QRandomGenerator>
#include <QSaveFile>
#include <QSerialPortInfo>
#include <QSettings>
#include <QStandardPaths>
#include <QStorageInfo>
#include <QTimer>
#include <QtConcurrent>
#include <QtEndian>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <exception>

namespace {
bool copyFileAtomically(const QString &sourcePath, const QString &targetPath,
                        QString *error, qint64 maximumBytes = -1)
{
    QFile source(sourcePath);
    if (!source.open(QIODevice::ReadOnly)) {
        *error = QStringLiteral("无法读取电脑播放副本：%1")
                     .arg(source.errorString());
        return false;
    }
    QSaveFile target(targetPath);
    if (!target.open(QIODevice::WriteOnly)) {
        *error = QStringLiteral("无法在TF卡建立电脑播放副本：%1")
                     .arg(target.errorString());
        return false;
    }
    QByteArray block(256 * 1024, Qt::Uninitialized);
    qint64 remaining = maximumBytes;
    while (!source.atEnd() && remaining != 0) {
        const qint64 requested = remaining < 0
            ? block.size() : std::min<qint64>(block.size(), remaining);
        const qint64 count = source.read(block.data(), requested);
        if (count < 0 || target.write(block.constData(), count) != count) {
            target.cancelWriting();
            *error = QStringLiteral("复制电脑播放文件时发生读写错误。");
            return false;
        }
        if (remaining > 0)
            remaining -= count;
    }
    if (!target.commit()) {
        *error = QStringLiteral("提交电脑播放副本失败：%1")
                     .arg(target.errorString());
        return false;
    }
    return true;
}

QString rawSongTitleFromMp3(const QString &mp3Path, const QString &fallbackTitle)
{
    QString title = QFileInfo(QDir::fromNativeSeparators(mp3Path)).completeBaseName().trimmed();
    if (title.isEmpty())
        title = fallbackTitle.trimmed();

    title.replace(QRegularExpression(QStringLiteral(R"([<>:\"/\\|?*\x00-\x1F])")),
                  QStringLiteral("_"));
    title.replace(QRegularExpression(QStringLiteral(R"(\s+)")), QStringLiteral(" "));
    while (title.endsWith(QLatin1Char(' ')) || title.endsWith(QLatin1Char('.')))
        title.chop(1);
    if (title.size() > 80)
        title = title.left(80).trimmed();
    return title;
}
PackageResult currentTaskException(const QString &operation)
{
    PackageResult result;
    try {
        throw;
    } catch (const std::exception &error) {
        result.error = QStringLiteral("%1发生异常：%2")
                           .arg(operation,
                                QString::fromLocal8Bit(error.what()));
    } catch (...) {
        result.error = QStringLiteral("%1发生未知异常。")
                           .arg(operation);
    }
    return result;
}

}

AppController::AppController(QObject *parent)
    : QObject(parent),
      m_audioOutput(this),
      m_bufferOutput(this),
      m_player(this),
      m_analyzer(this),
      m_converter(this),
      m_serial(this),
      m_systemAudioMonitor(this)
{
    m_audioOutput.setVolume(0.72);
    m_player.setAudioOutput(&m_audioOutput);
    m_player.setAudioBufferOutput(&m_bufferOutput);

    for (int i = 0; i < 48; ++i)
        m_spectrum.push_back(0.0);
    for (int i = 0; i < 96; ++i)
        m_waveform.push_back(0.0);
    for (int i = 0; i < 48; ++i) {
        m_boardSpectrum.push_back(0.0);
        m_systemSpectrum.push_back(0.0);
    }
    for (int i = 0; i < 96; ++i) {
        m_boardWaveform.push_back(0.0);
        m_systemWaveform.push_back(0.0);
    }

    // Board firmware revisions that return the legacy 9-byte STATUS do not
    // provide audio levels.  Animate from the latest status at a UI-friendly
    // rate, and use Windows loopback data while the board source is LINE IN.
    // Keep the board visualizer responsive without allowing it to invent
    // motion while the board is stopped.  updateBoardVisualization() gates
    // every frame using the status state and real input signal.
    m_boardAnimationTimer.setInterval(33);
    connect(&m_boardAnimationTimer, &QTimer::timeout, this, [this] {
        updateBoardVisualization(m_boardStatus);
    });
    m_boardAnimationTimer.start();

    connect(&m_bufferOutput, &QAudioBufferOutput::audioBufferReceived,
            &m_analyzer, &AudioAnalyzer::consume);
    connect(&m_analyzer, &AudioAnalyzer::analysisReady, this,
            [this](const QVariantList &spectrum,
                   const QVariantList &waveform,
                   double left, double right, double peak) {
                m_spectrum = spectrum;
                m_waveform = waveform;
                m_leftLevel = left;
                m_rightLevel = right;
                m_peakLevel = peak;
                emit spectrumChanged();
                emit waveformChanged();
                emit levelsChanged();
            });
    connect(&m_player, &QMediaPlayer::playbackStateChanged,
            this, [this] {
                emit playbackChanged();
                // QAudioBufferOutput can deliver one or two buffers after a
                // pause/stop.  Clear the analyzer immediately so all three
                // visualizers become still instead of showing stale audio.
                if (!playing())
                    m_analyzer.reset();
            });
    connect(&m_player, &QMediaPlayer::positionChanged,
            this, [this](qint64 value) {
                emit positionChanged();
                updateCurrentLyric(value);
                emit currentBoardPreviewChanged();
            });
    connect(&m_player, &QMediaPlayer::durationChanged,
            this, &AppController::durationChanged);
    connect(&m_player, &QMediaPlayer::metaDataChanged, this, [this] {
        const QMediaMetaData metadata = m_player.metaData();
        const QString detectedArtist = metadata.stringValue(
            QMediaMetaData::ContributingArtist);
        bool changed = false;
        // The song title is deliberately derived from the selected MP3 file
        // name (without the extension).  Do not let an embedded ID3 title
        // replace it, because that would turn e.g.
        // "Talking to the Moon - Bruno Mars.mp3" into only
        // "Talking to the Moon" after QMediaPlayer finishes loading metadata.
        if (!detectedArtist.isEmpty()) {
            m_artist = detectedArtist;
            changed = true;
        }
        if (changed) {
            emit metadataChanged();
            if (!m_lrcPath.isEmpty())
                parseLyrics();
        }
    });
    connect(&m_player, &QMediaPlayer::errorOccurred,
            this, [this](QMediaPlayer::Error, const QString &error) {
                if (!error.isEmpty())
                    setToast(QStringLiteral("播放器：%1").arg(error));
            });
    connect(&m_player, &QMediaPlayer::mediaStatusChanged,
            this, [this](QMediaPlayer::MediaStatus status) {
                if (status == QMediaPlayer::EndOfMedia)
                    advanceLocalAfterEnd();
            });

    connect(&m_audioOutput, &QAudioOutput::volumeChanged,
            this, &AppController::volumeChanged);
    connect(&m_converter, &AudioConverter::progressChanged,
            this, [this](double value, const QString &stage) {
                setTaskState(true, value, stage);
            });
    connect(&m_converter, &AudioConverter::failed, this,
            [this](const QString &error) {
                m_uploadToBoardAfterBuild = false;
                setTaskState(false, 0.0, error);
                setToast(error);
            });
    connect(&m_converter, &AudioConverter::finished,
            this, [this](const QString &rawPath, qint64 durationMs, quint64) {
                // QAudioDecoder emits finished while its backend is still
                // unwinding.  Starting QtConcurrent from that stack caused
                // sporadic process termination with the Windows FFmpeg
                // backend.  Queue the next stage onto the GUI event loop.
                QTimer::singleShot(0, this, [this, rawPath, durationMs] {
                    startPackageWorker(rawPath, durationMs);
                });
            });
    connect(&m_worker, &QFutureWatcher<PackageResult>::finished,
            this, &AppController::handleWorkerFinished);

    auto forwardSerialState = [this] { emit serialStateChanged(); };
    connect(&m_serial, &SerialLink::openChanged, this, forwardSerialState);
    connect(&m_serial, &SerialLink::boardOnlineChanged, this, forwardSerialState);
    connect(&m_serial, &SerialLink::statusChanged, this, forwardSerialState);
    connect(&m_serial, &SerialLink::uploadProgressChanged, this, forwardSerialState);
    connect(&m_serial, &SerialLink::uploadActiveChanged, this, forwardSerialState);
    connect(&m_serial, &SerialLink::uploadStarted, this,
            [this](int track, quint64) {
                setTaskState(true, 0.0,
                    QStringLiteral("开始上传曲目%1（%2）…")
                        .arg(track)
                        .arg(SongPackage::boardTrackFileName(track)));
            });
    connect(&m_serial, &SerialLink::uploadProgressChanged, this, [this] {
        if (m_serial.uploadActive())
            setTaskState(true, m_serial.uploadProgress(), m_serial.status());
    });
    connect(&m_serial, &SerialLink::errorOccurred,
            this, [this](const QString &message) { setToast(message); });
    connect(&m_serial, &SerialLink::messageReceived,
            this, [this](const QString &message) { setToast(message); });
    connect(&m_serial, &SerialLink::uploadFinished, this, [this] {
        rememberBoardLyrics(m_lastBoardUploadTrack);
        setTaskState(false, 1.0,
                     QStringLiteral("板载TF卡写入和CRC校验完成"));
        setToast(QStringLiteral(
            "歌曲音频和歌词已写入板载TF卡，正在切换到曲目%1验证。")
                     .arg(m_lastBoardUploadTrack));
        QTimer::singleShot(350, this, [this] {
            boardSelectTrack(m_lastBoardUploadTrack);
        });
        QTimer::singleShot(900, this, [this] {
            refreshBoardTfDirectory();
        });
    });
    connect(&m_serial, &SerialLink::uploadFailed, this,
            [this](const QString &message) {
                m_uploadToBoardAfterBuild = false;
                setTaskState(false, 0.0, message);
    });
    connect(&m_serial, &SerialLink::slotCleared, this, [this](int track) {
        QSettings settings;
        settings.beginGroup(QStringLiteral("BoardLyrics"));
        settings.remove(QString::number(track));
        settings.endGroup();
        settings.sync();
        setTaskState(false, 1.0,
                     QStringLiteral("板载TF卡曲目%1已删除/清空").arg(track));
        setToast(QStringLiteral("曲目%1已逻辑删除；歌曲名映射已同步清除，文件槽保留供以后覆盖。")
                     .arg(track));
        QTimer::singleShot(300, this, [this] { refreshBoardTfDirectory(); });
    });
    connect(&m_serial, &SerialLink::slotScanStarted, this, [this] {
        m_boardTfScanActive = true;
        emit boardTfDirectoryChanged();
    });
    connect(&m_serial, &SerialLink::slotInfoReceived, this,
            [this](const QVariantMap &info) {
                const int track = info.value(QStringLiteral("track"), -1).toInt();
                if (track < 0 || track > 14)
                    return;
                while (m_boardTfMusicFiles.size() < 15) {
                    const int i = m_boardTfMusicFiles.size();
                    const bool builtin = i < 5;
                    QVariantMap placeholder;
                    placeholder.insert(QStringLiteral("slot"), builtin ? -1 : i - 5);
                    placeholder.insert(QStringLiteral("track"), i);
                    placeholder.insert(QStringLiteral("builtin"), builtin);
                    QString fileName;
                    switch (i) {
                    case 0: fileName = QStringLiteral("SONG.RAW"); break;
                    case 1: fileName = QStringLiteral("BEAUTY.RAW"); break;
                    case 2: fileName = QStringLiteral("DIE4YOU.RAW"); break;
                    case 3: fileName = QStringLiteral("PAYPHONE.RAW"); break;
                    case 4: fileName = QStringLiteral("STARBOY.RAW"); break;
                    default:
                        fileName = QStringLiteral("USR%1.RAW")
                            .arg(i - 5, 2, 10, QLatin1Char('0'));
                        break;
                    }
                    placeholder.insert(QStringLiteral("fileName"), fileName);
                    placeholder.insert(QStringLiteral("title"),
                                       QStringLiteral("正在读取…"));
                    placeholder.insert(QStringLiteral("present"), false);
                    placeholder.insert(QStringLiteral("valid"), false);
                    placeholder.insert(QStringLiteral("error"), -1);
                    placeholder.insert(QStringLiteral("fileSize"), 0);
                    m_boardTfMusicFiles.push_back(placeholder);
                }
                QVariantMap displayInfo = info;
                const bool present = displayInfo.value(QStringLiteral("present")).toBool();
                const bool valid = displayInfo.value(QStringLiteral("valid")).toBool();
                if (present && valid) {
                    QSettings settings;
                    settings.beginGroup(QStringLiteral("BoardLyrics"));
                    settings.beginGroup(QString::number(track));
                    QString savedTitle = settings.value(QStringLiteral("title")).toString().trimmed();
                    settings.endGroup();
                    settings.endGroup();
                    if (!savedTitle.isEmpty())
                        displayInfo.insert(QStringLiteral("title"), savedTitle);
                }
                m_boardTfMusicFiles[track] = displayInfo;
                emit boardTfDirectoryChanged();
            });
    connect(&m_serial, &SerialLink::slotScanFinished, this, [this] {
        m_boardTfScanActive = false;
        emit boardTfDirectoryChanged();
        setToast(QStringLiteral("板载TF卡目录读取完成：已检查15个RAW曲目。"));
    });
    connect(&m_serial, &SerialLink::boardOnlineChanged, this, [this] {
        if (m_serial.boardOnline())
            return;
        m_boardSdReady = false;
        m_boardSdReadyKnown = false;
        m_boardExternalSignal = false;
        m_boardExternalSignalKnown = false;
        m_boardControlsConfirmed = false;
        m_lastBoardPlayMs = -1;
        m_boardMotionTicks = 0;
        m_boardVisualizationActive = false;
        m_boardTfScanActive = false;
        m_boardLcdPageIndex = -1;
        m_boardLcdTrack = -1;
        m_boardTfMusicFiles.clear();
        emit boardTfDirectoryChanged();
        emit boardStatusChanged();
    });
    connect(&m_serial, &SerialLink::boardStatusReceived, this,
            [this](const QVariantMap &status) {
                const int previousSource = m_boardStatus.value(
                    QStringLiteral("source"), -1).toInt();
                const int previousTrack = m_boardStatus.value(
                    QStringLiteral("track"), -1).toInt();
                m_boardStatus = status;
                const int source = status.value(QStringLiteral("source"), 0).toInt();
                const int track = status.value(QStringLiteral("track"), 0).toInt();
                const int error = status.value(QStringLiteral("error"), 0).toInt();
                const qint64 boardMs = status.value(
                    QStringLiteral("playMs"), 0).toLongLong();

                m_boardSdReadyKnown = status.value(
                    QStringLiteral("sdReadyKnown"), false).toBool();
                if (m_boardSdReadyKnown) {
                    m_boardSdReady = status.value(
                        QStringLiteral("sdReady"), false).toBool();
                } else if (source == 0) {
                    // Legacy STATUS has no TF-card flag. Preserve the inference
                    // while another source is selected, but update it whenever
                    // the board reports the TF-card source again.
                    m_boardSdReady = error == 0;
                }

                m_boardExternalSignalKnown = status.value(
                    QStringLiteral("externalSignalKnown"), false).toBool();
                m_boardExternalSignal = m_boardExternalSignalKnown
                    && status.value(QStringLiteral("externalSignal"), false).toBool();
                m_boardControlsConfirmed = status.value(
                    QStringLiteral("controlsKnown"), false).toBool();
                if (m_boardControlsConfirmed) {
                    // STATUS packets can arrive a little behind a rapid slider
                    // gesture.  Do not let an old telemetry value snap the QML
                    // handle backwards immediately after a local command.
                    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
                    if (nowMs >= m_ignoreBoardVolumeStatusUntil) {
                        m_boardVolume = qBound(0, status.value(
                            QStringLiteral("volume"), m_boardVolume).toInt(), 100);
                    }
                    if (nowMs >= m_ignoreBoardToneStatusUntil) {
                        m_boardTone = qBound(0, status.value(
                            QStringLiteral("tone"), m_boardTone).toInt(), 100);
                    }
                    m_boardSpeakerEnabled = status.value(
                        QStringLiteral("speakerEnabled"),
                        m_boardSpeakerEnabled).toBool();
                }

                if (m_lastBoardPlayMs >= 0 && boardMs != m_lastBoardPlayMs)
                    m_boardMotionTicks = 12;
                m_lastBoardPlayMs = boardMs;
                if (source != previousSource || track != previousTrack
                    || source != m_loadedBoardLyricSource
                    || track != m_loadedBoardLyricTrack) {
                    loadBoardLyrics(source, track);
                }
                updateBoardLyricPosition(boardMs);
                updateBoardLcdLyricPage(boardMs);
                updateBoardVisualization(status);
                const bool copyActive = status.value(
                    QStringLiteral("qspiCopyActive"), false).toBool();
                const bool copyOk = status.value(
                    QStringLiteral("qspiCopyOk"), false).toBool();
                const bool copyFailed = status.value(
                    QStringLiteral("qspiCopyFailed"), false).toBool();
                if (m_qspiCopyRequested) {
                    if (copyActive) {
                        m_qspiCopySeenActive = true;
                    } else if (m_qspiCopySeenActive && copyOk) {
                        m_qspiCopyRequested = false;
                        m_qspiCopySeenActive = false;
                        setToast(QStringLiteral(
                            "当前10秒片段已写入并校验完成，正在切换到QSFLASH播放。"));
                        QTimer::singleShot(300, this, [this] {
                            boardSelectSource(1);
                        });
                    } else if (m_qspiCopySeenActive && copyFailed) {
                        m_qspiCopyRequested = false;
                        m_qspiCopySeenActive = false;
                        setToast(QStringLiteral(
                            "QSFLASH写入失败；请查看板载LCD错误提示，并确认当前TF卡歌曲剩余时长至少10秒。"));
                    }
                }
                emit boardStatusChanged();
            });

    connect(&m_systemAudioMonitor, &SystemAudioMonitor::analysisReady,
            this, [this](const QVariantList &spectrum,
                         const QVariantList &waveform,
                         double left, double right, double peak,
                         bool signalActive) {
                m_systemSpectrum = spectrum;
                m_systemWaveform = waveform;
                m_systemLeftLevel = left;
                m_systemRightLevel = right;
                m_systemPeakLevel = peak;
                m_systemAudioSignal = signalActive;
                emit systemAudioChanged();
            });
    connect(&m_systemAudioMonitor, &SystemAudioMonitor::statusChanged,
            this, [this](const QString &status, bool available) {
                m_systemAudioStatus = status;
                m_systemAudioAvailable = available;
                emit systemAudioStatusChanged();
            }, Qt::QueuedConnection);

    refreshSerialPorts();
    refreshStorageVolumes();
    loadCompanionLibrary();
    m_systemAudioMonitor.start();
}

AppController::~AppController()
{
    m_converter.cancel();
    m_systemAudioMonitor.stop();
    if (m_worker.isRunning()) {
        m_worker.future().cancel();
        m_worker.waitForFinished();
    }
}

bool AppController::playing() const
{
    return m_player.playbackState() == QMediaPlayer::PlayingState;
}

bool AppController::boardSdReady() const
{
    return m_boardSdReady;
}

bool AppController::boardExternalSignal() const
{
    return m_boardExternalSignal;
}

bool AppController::qspiCopyBusy() const
{
    return m_qspiCopyRequested
        || m_boardStatus.value(QStringLiteral("qspiCopyActive"), false).toBool();
}

QString AppController::currentLyric() const
{
    return m_currentLyricIndex >= 0 && m_currentLyricIndex < m_lyricLines.size()
        ? m_lyricLines.at(m_currentLyricIndex) : QString();
}

QString AppController::previousLyric() const
{
    return m_currentLyricIndex > 0
        ? m_lyricLines.at(m_currentLyricIndex - 1) : QString();
}

QString AppController::nextLyric() const
{
    return m_currentLyricIndex >= 0
        && m_currentLyricIndex + 1 < m_lyricLines.size()
        ? m_lyricLines.at(m_currentLyricIndex + 1) : QString();
}

QString AppController::currentBoardPreview() const
{
    if (m_lrcResult.boardPages.isEmpty())
        return QStringLiteral("等待生成板载两行歌词预览");
    int page = 0;
    const qint64 time = m_player.position();
    for (int i = 1; i < m_lrcResult.boardPages.size(); ++i) {
        if (m_lrcResult.boardPages.at(i).timeMs > time)
            break;
        page = i;
    }
    const BoardLyricPage &value = m_lrcResult.boardPages.at(page);
    return QStringLiteral("%1  /  %2")
        .arg(value.previewLine1, value.previewLine2);
}

void AppController::setImportMp3(const QUrl &url)
{
    const QString path = url.toLocalFile();
    if (path.isEmpty() || !QFileInfo::exists(path)) {
        setToast(QStringLiteral("所选MP3不存在。"));
        return;
    }
    const QString nativePath = QDir::toNativeSeparators(path);
    const bool changedSong = m_mp3Path != nativePath;
    m_mp3Path = nativePath;
    if (changedSong && !m_lrcPath.isEmpty()) {
        // Never silently reuse the previous song's lyrics for a newly selected MP3.
        m_lrcPath.clear();
        m_lrcResult = {};
        m_lyricLines.clear();
        m_boardPreview.clear();
        m_currentLyricIndex = -1;
        emit lyricsChanged();
        emit currentLyricChanged();
        emit currentBoardPreviewChanged();
    }
    const QString base = QFileInfo(path).completeBaseName().trimmed();
    // The visible song name is always the complete MP3 filename with only the
    // .mp3 suffix removed.  The artist field may still be filled separately,
    // but it must not shorten or otherwise rewrite the song name.
    m_title = base;
    static const QRegularExpression titleArtistSpaced(QStringLiteral(R"(\s+[-–—]\s+)"));
    QRegularExpressionMatch titleArtistMatch = titleArtistSpaced.match(base);
    if (!titleArtistMatch.hasMatch()) {
        static const QRegularExpression titleArtistCompact(QStringLiteral(R"([-–—])"));
        titleArtistMatch = titleArtistCompact.match(base);
    }
    if (titleArtistMatch.hasMatch() && titleArtistMatch.capturedStart() > 0) {
        m_artist = base.mid(titleArtistMatch.capturedEnd()).trimmed();
    } else {
        m_artist.clear();
    }
    m_player.setSource(QUrl::fromLocalFile(path));
    m_analyzer.reset();
    emit importFilesChanged();
    emit metadataChanged();
    if (!m_lrcPath.isEmpty())
        parseLyrics();
    refreshMusicDirectories(m_musicVolumeRoot);
    setToast(QStringLiteral("MP3已载入，可以试听或转换。"));
}

void AppController::setImportLrc(const QUrl &url)
{
    const QString path = url.toLocalFile();
    if (path.isEmpty() || !QFileInfo::exists(path)) {
        setToast(QStringLiteral("所选LRC不存在。"));
        return;
    }
    m_lrcPath = QDir::toNativeSeparators(path);
    emit importFilesChanged();
    parseLyrics();
}

void AppController::togglePlay()
{
    if (m_mp3Path.isEmpty()) {
        setToast(QStringLiteral("请先选择MP3。"));
        return;
    }
    if (playing())
        m_player.pause();
    else
        m_player.play();
}

void AppController::stopPlayback()
{
    m_player.stop();
    m_analyzer.reset();
}

void AppController::seekNormalized(double ratio)
{
    if (m_player.duration() <= 0)
        return;
    m_player.setPosition(static_cast<qint64>(
        qBound(0.0, ratio, 1.0) * double(m_player.duration())));
}

void AppController::setVolume(double volume)
{
    m_audioOutput.setVolume(qBound(0.0, volume, 1.0));
}

void AppController::setPlaybackRate(double rate)
{
    const double bounded = qBound(0.75, rate, 1.25);
    if (qFuzzyCompare(m_player.playbackRate(), bounded))
        return;
    m_player.setPlaybackRate(bounded);
    emit playbackRateChanged();
}

void AppController::setPcAudioEnabled(bool enabled)
{
    if (m_pcAudioEnabled == enabled)
        return;
    m_pcAudioEnabled = enabled;
    m_audioOutput.setMuted(!enabled);
    emit pcAudioEnabledChanged();
}

void AppController::setTitle(const QString &title)
{
    const QString value = title.simplified();
    if (value == m_title)
        return;
    m_title = value;
    emit metadataChanged();
    if (!m_lrcPath.isEmpty())
        parseLyrics();
}

void AppController::setArtist(const QString &artist)
{
    const QString value = artist.simplified();
    if (value == m_artist)
        return;
    m_artist = value;
    emit metadataChanged();
}

void AppController::refreshSerialPorts()
{
    QStringList ports;
    for (const QSerialPortInfo &info : QSerialPortInfo::availablePorts()) {
        QString label = info.portName();
        if (!info.description().isEmpty())
            label += QStringLiteral("  —  ") + info.description();
        ports.push_back(label);
    }
    m_serialPorts = ports;
    emit serialPortsChanged();
}

void AppController::playLibraryIndex(int index, bool startPlayback)
{
    if (index < 0 || index >= m_librarySongs.size()) {
        setToast(QStringLiteral("配套歌曲编号无效。"));
        return;
    }
    const QVariantMap song = m_librarySongs.at(index).toMap();
    const QString mp3 = song.value(QStringLiteral("mp3Path")).toString();
    const QString lrc = song.value(QStringLiteral("lrcPath")).toString();
    if (!QFileInfo::exists(mp3)) {
        setToast(QStringLiteral("配套歌曲文件缺失，请检查程序旁的media目录。"));
        return;
    }
    m_currentLibraryIndex = index;
    emit currentLibraryIndexChanged();
    setImportMp3(QUrl::fromLocalFile(mp3));
    setTitle(song.value(QStringLiteral("title")).toString());
    setArtist(song.value(QStringLiteral("artist")).toString());
    if (QFileInfo::exists(lrc))
        setImportLrc(QUrl::fromLocalFile(lrc));
    if (startPlayback)
        m_player.play();
}

void AppController::loadLibrarySong(int index)
{
    playLibraryIndex(index, false);
    if (index >= 0 && index < m_librarySongs.size())
        setToast(QStringLiteral("已载入配套歌曲：%1").arg(m_title));
}

void AppController::selectLocalSong(int index)
{
    playLibraryIndex(index, true);
}

void AppController::previousLocalSong()
{
    if (m_librarySongs.isEmpty())
        return;
    int index = m_currentLibraryIndex;
    if (m_playbackMode == 3 && m_librarySongs.size() > 1) {
        do {
            index = QRandomGenerator::global()->bounded(m_librarySongs.size());
        } while (index == m_currentLibraryIndex);
    } else if (index < 0) {
        index = 0;
    } else {
        index = (index + m_librarySongs.size() - 1) % m_librarySongs.size();
    }
    playLibraryIndex(index, true);
}

void AppController::nextLocalSong()
{
    if (m_librarySongs.isEmpty())
        return;
    int index = m_currentLibraryIndex;
    if (m_playbackMode == 3 && m_librarySongs.size() > 1) {
        do {
            index = QRandomGenerator::global()->bounded(m_librarySongs.size());
        } while (index == m_currentLibraryIndex);
    } else if (index < 0) {
        index = 0;
    } else {
        index = (index + 1) % m_librarySongs.size();
    }
    playLibraryIndex(index, true);
}

QString AppController::playbackModeName() const
{
    switch (m_playbackMode) {
    case 1: return QStringLiteral("单曲循环");
    case 2: return QStringLiteral("列表循环");
    case 3: return QStringLiteral("随机播放");
    default: return QStringLiteral("顺序播放");
    }
}

void AppController::setPlaybackMode(int mode)
{
    const int bounded = qBound(0, mode, 3);
    if (m_playbackMode == bounded)
        return;
    m_playbackMode = bounded;
    emit playbackModeChanged();
}

void AppController::advanceLocalAfterEnd()
{
    if (m_librarySongs.isEmpty() || m_currentLibraryIndex < 0)
        return;
    if (m_playbackMode == 1) {
        m_player.setPosition(0);
        m_player.play();
        return;
    }
    int next = m_currentLibraryIndex;
    if (m_playbackMode == 3 && m_librarySongs.size() > 1) {
        do {
            next = QRandomGenerator::global()->bounded(m_librarySongs.size());
        } while (next == m_currentLibraryIndex);
    } else if (m_currentLibraryIndex + 1 < m_librarySongs.size()) {
        next = m_currentLibraryIndex + 1;
    } else if (m_playbackMode == 2) {
        next = 0;
    } else {
        return;
    }
    playLibraryIndex(next, true);
}

void AppController::refreshMusicDirectories(const QString &volumeRoot)
{
    m_musicVolumeRoot = volumeRoot;

    // "电脑本地目录" is the music library, not just the folder that happens
    // to contain the currently selected MP3. Merge the bundled playlist with
    // audio files next to the currently selected/imported MP3.
    QVariantList local;
    QHash<QString, QVariantMap> localByPath;

    const auto addLocalAudio = [&localByPath](const QString &audioPath,
                                               const QString &displayName,
                                               const QString &lrcPath) {
        QFileInfo info(QDir::fromNativeSeparators(audioPath));
        if (!info.exists() || !info.isFile())
            return;
        const QString absolute = QDir::cleanPath(info.absoluteFilePath());
        const QString key = absolute.toCaseFolded();
        QVariantMap item;
        item.insert(QStringLiteral("name"),
                    displayName.isEmpty() ? info.fileName() : displayName);
        item.insert(QStringLiteral("path"),
                    QDir::toNativeSeparators(absolute));
        item.insert(QStringLiteral("size"), info.size());
        item.insert(QStringLiteral("lrcPath"),
                    QDir::toNativeSeparators(lrcPath));
        item.insert(QStringLiteral("hasLrc"),
                    !lrcPath.isEmpty() && QFileInfo::exists(lrcPath));
        localByPath.insert(key, item);
    };

    for (const QVariant &entry : m_librarySongs) {
        const QVariantMap song = entry.toMap();
        QString label = song.value(QStringLiteral("title")).toString();
        const QString artist = song.value(QStringLiteral("artist")).toString();
        if (!artist.isEmpty())
            label += QStringLiteral(" - ") + artist;
        addLocalAudio(song.value(QStringLiteral("mp3Path")).toString(),
                      label,
                      song.value(QStringLiteral("lrcPath")).toString());
    }

    const QString current = QDir::fromNativeSeparators(m_mp3Path);
    const QString scanPath = current.isEmpty()
        ? QStandardPaths::writableLocation(QStandardPaths::MusicLocation)
        : QFileInfo(current).absolutePath();

    QDir localDir(scanPath);
    const QStringList audioFilters = {QStringLiteral("*.mp3"), QStringLiteral("*.MP3"),
                                      QStringLiteral("*.wav"), QStringLiteral("*.WAV"),
                                      QStringLiteral("*.flac"), QStringLiteral("*.FLAC")};
    for (const QFileInfo &info :
         localDir.entryInfoList(audioFilters, QDir::Files, QDir::Name)) {
        QString companionLrc = localDir.filePath(info.completeBaseName()
                                                 + QStringLiteral(".lrc"));
        if (!QFileInfo::exists(companionLrc))
            companionLrc.clear();
        addLocalAudio(info.absoluteFilePath(), info.fileName(), companionLrc);
    }

    QStringList localKeys = localByPath.keys();
    std::sort(localKeys.begin(), localKeys.end(),
              [&localByPath](const QString &a, const QString &b) {
                  return QString::localeAwareCompare(
                             localByPath.value(a).value(QStringLiteral("name")).toString(),
                             localByPath.value(b).value(QStringLiteral("name")).toString()) < 0;
              });
    for (const QString &key : localKeys)
        local.push_back(localByPath.value(key));
    m_localMusicFiles = local;

    QVariantList sd;
    if (!volumeRoot.isEmpty()) {
        QDir dir(QDir::fromNativeSeparators(volumeRoot));
        QHash<QString, QVariantMap> groups;
        const QStringList filters = {QStringLiteral("*.LRC"), QStringLiteral("*.lrc"),
                                     QStringLiteral("*.RAW"), QStringLiteral("*.raw"),
                                     QStringLiteral("*.WAV"), QStringLiteral("*.wav"),
                                     QStringLiteral("*.FLAC"), QStringLiteral("*.flac")};
        for (const QFileInfo &info : dir.entryInfoList(filters, QDir::Files, QDir::Name)) {
            const QString displayBase = info.completeBaseName();
            const QString key = displayBase.toUpper();
            QVariantMap item = groups.value(key);
            item.insert(QStringLiteral("baseName"), displayBase);
            item.insert(QStringLiteral("display"), displayBase);
            item.insert(QStringLiteral("root"), QDir::toNativeSeparators(dir.absolutePath()));
            QStringList files = item.value(QStringLiteral("files")).toStringList();
            const QString absolute = QDir::toNativeSeparators(info.absoluteFilePath());
            if (!files.contains(absolute, Qt::CaseInsensitive))
                files.push_back(absolute);
            item.insert(QStringLiteral("files"), files);
            groups.insert(key, item);
        }
        QStringList keys = groups.keys();
        std::sort(keys.begin(), keys.end());
        for (const QString &key : keys)
            sd.push_back(groups.value(key));
    }
    m_sdMusicFiles = sd;
    emit musicDirectoriesChanged();
}

void AppController::deleteLocalMusicFile(const QString &path)
{
    if (path.isEmpty())
        return;

    const QString normalized = QDir::cleanPath(QDir::fromNativeSeparators(path));
    QFile file(normalized);
    if (!file.exists()) {
        setToast(QStringLiteral("文件不存在。"));
        refreshMusicDirectories(m_musicVolumeRoot);
        return;
    }

    // Windows keeps the currently loaded media file open.  Release the
    // QMediaPlayer source before deleting it so the Import page can delete
    // the song that is currently selected/playing instead of reporting
    // "another program is using this file".
    const QString currentSource = QDir::cleanPath(
        QDir::fromNativeSeparators(m_player.source().toLocalFile()));
    if (!currentSource.isEmpty() &&
        QString::compare(currentSource, normalized, Qt::CaseInsensitive) == 0) {
        m_player.stop();
        m_player.setSource(QUrl());
        m_analyzer.reset();
        if (QString::compare(QDir::cleanPath(QDir::fromNativeSeparators(m_mp3Path)),
                             normalized, Qt::CaseInsensitive) == 0) {
            m_mp3Path.clear();
            emit importFilesChanged();
        }
        emit playbackChanged();
        emit positionChanged();
        emit durationChanged();
    }

    if (!file.remove()) {
        // Some Windows audio backends release the handle one event-loop turn
        // later. Retry once after the source has been detached.
        QTimer::singleShot(160, this, [this, normalized] {
            QFile retry(normalized);
            if (!retry.exists()) {
                refreshMusicDirectories(m_musicVolumeRoot);
                return;
            }
            if (retry.remove())
                setToast(QStringLiteral("已删除本地文件。"));
            else
                setToast(QStringLiteral("删除失败：%1").arg(retry.errorString()));
            refreshMusicDirectories(m_musicVolumeRoot);
        });
        return;
    }
    setToast(QStringLiteral("已删除本地文件。"));
    refreshMusicDirectories(m_musicVolumeRoot);
}

void AppController::deleteSdSong(const QString &baseName, const QString &volumeRoot)
{
    if (baseName.isEmpty() || volumeRoot.isEmpty())
        return;
    QDir dir(volumeRoot);
    if (!dir.exists()) {
        setToast(QStringLiteral("TF卡路径不存在，请重新插入并刷新。"));
        return;
    }

    bool removedAny = false;
    QString lastError;
    const QStringList supported = {QStringLiteral("lrc"), QStringLiteral("raw")};
    const QFileInfoList entries = dir.entryInfoList(QDir::Files | QDir::NoDotAndDotDot);
    for (const QFileInfo &info : entries) {
        if (QString::compare(info.completeBaseName(), baseName, Qt::CaseInsensitive) != 0
            || !supported.contains(info.suffix(), Qt::CaseInsensitive))
            continue;
        QFile file(info.absoluteFilePath());
        if (file.remove())
            removedAny = true;
        else
            lastError = file.errorString();
    }
    if (removedAny)
        setToast(QStringLiteral("已删除TF卡中的所选歌曲文件。"));
    else if (!lastError.isEmpty())
        setToast(QStringLiteral("TF卡删除失败：%1").arg(lastError));
    else
        setToast(QStringLiteral("没有找到可删除的TF卡歌曲文件。"));
    refreshMusicDirectories(volumeRoot);
}

void AppController::boardClearSlot(int boardTrack)
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    if (boardSdReadyKnown() && !boardSdReady()) {
        setToast(QStringLiteral("板载TF卡未就绪，无法删除歌曲。"));
        return;
    }
    const int track = qBound(0, boardTrack, 14);
    if (m_serial.uploadActive()) {
        setToast(QStringLiteral("TF卡正在执行写入任务，请稍后再删除。"));
        return;
    }

    // The FPGA performs a safe logical delete by setting the FAT directory
    // file size to zero while preserving the already allocated cluster chain.
    // That keeps the slot recoverable for a later board-side overwrite and
    // avoids mutating FAT chains from the FPGA.
    m_serial.clearSlot(track);
    setToast(QStringLiteral("正在删除板载TF卡曲目%1；文件槽会保留为0字节，便于以后恢复/覆盖。")
                 .arg(track));
}

void AppController::refreshBoardTfDirectory()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口，再读取TF卡目录。"));
        return;
    }
    if (boardSdReadyKnown() && !boardSdReady()) {
        m_boardTfMusicFiles.clear();
        emit boardTfDirectoryChanged();
        setToast(QStringLiteral("FPGA当前没有检测到可用TF卡。"));
        return;
    }
    if (m_serial.uploadActive()) {
        setToast(QStringLiteral("TF卡正在写入，完成后再刷新目录。"));
        return;
    }

    QSettings titleSettings;
    titleSettings.beginGroup(QStringLiteral("BoardLyrics"));
    m_boardTfMusicFiles.clear();
    for (int track = 0; track < 15; ++track) {
        const bool builtin = track < 5;
        QVariantMap item;
        item.insert(QStringLiteral("slot"), builtin ? -1 : track - 5);
        item.insert(QStringLiteral("track"), track);
        item.insert(QStringLiteral("builtin"), builtin);
        QString fileName;
        switch (track) {
        case 0: fileName = QStringLiteral("SONG.RAW"); break;
        case 1: fileName = QStringLiteral("BEAUTY.RAW"); break;
        case 2: fileName = QStringLiteral("DIE4YOU.RAW"); break;
        case 3: fileName = QStringLiteral("PAYPHONE.RAW"); break;
        case 4: fileName = QStringLiteral("STARBOY.RAW"); break;
        default:
            fileName = QStringLiteral("USR%1.RAW")
                .arg(track - 5, 2, 10, QLatin1Char('0'));
            break;
        }
        item.insert(QStringLiteral("fileName"), fileName);
        const QString savedTitle = titleSettings.value(
            QStringLiteral("%1/title").arg(track)).toString().trimmed();
        item.insert(QStringLiteral("title"), savedTitle.isEmpty()
            ? QStringLiteral("正在读取…") : savedTitle);
        item.insert(QStringLiteral("present"), false);
        item.insert(QStringLiteral("valid"), false);
        item.insert(QStringLiteral("error"), -1);
        item.insert(QStringLiteral("fileSize"), 0);
        m_boardTfMusicFiles.push_back(item);
    }
    titleSettings.endGroup();
    m_boardTfScanActive = true;
    emit boardTfDirectoryChanged();
    m_serial.querySlots();
}

void AppController::refreshStorageVolumes()
{
    QVariantList volumes;
    QHash<QString, bool> seenRoots;

    const auto considerStorage = [&volumes, &seenRoots](const QStorageInfo &storage) {
        if (!storage.isValid() || !storage.isReady())
            return;
        QString root = QDir::cleanPath(storage.rootPath());
        if (root.isEmpty())
            return;
        const QString rootKey = root.toCaseFolded();
        if (seenRoots.contains(rootKey))
            return;

        QString fs = QString::fromLatin1(storage.fileSystemType()).trimmed().toUpper();
        const bool fatFamily =
            fs == QStringLiteral("FAT32") || fs == QStringLiteral("VFAT")
            || fs == QStringLiteral("FAT") || fs == QStringLiteral("FAT16")
            || fs == QStringLiteral("FAT12") || fs == QStringLiteral("MSDOS");
        const bool exfat = fs == QStringLiteral("EXFAT");
        if (!fatFamily && !exfat)
            return;

        seenRoots.insert(rootKey, true);
        const bool writable = !storage.isReadOnly();
        const bool boardCompatible = fatFamily;
        QVariantMap item;
        item.insert(QStringLiteral("root"), QDir::toNativeSeparators(storage.rootPath()));
        item.insert(QStringLiteral("name"), storage.displayName());
        item.insert(QStringLiteral("fileSystem"), fs);
        item.insert(QStringLiteral("freeGiB"),
                    double(storage.bytesAvailable()) / 1'073'741'824.0);
        item.insert(QStringLiteral("boardCompatible"), boardCompatible);
        item.insert(QStringLiteral("writeCompatible"),
                    boardCompatible && writable);
        item.insert(QStringLiteral("display"),
                    QStringLiteral("%1  [%2]  %3 GiB可用%4")
                        .arg(storage.displayName().isEmpty()
                                 ? storage.rootPath() : storage.displayName(),
                             fs.isEmpty() ? QStringLiteral("UNKNOWN") : fs)
                        .arg(double(storage.bytesAvailable()) / 1'073'741'824.0,
                             0, 'f', 1)
                        .arg(!writable ? QStringLiteral("（只读）")
                             : boardCompatible ? QString()
                             : QStringLiteral("（电脑可读，板端需FAT32）")));
        volumes.push_back(item);
    };

    for (const QStorageInfo &storage : QStorageInfo::mountedVolumes())
        considerStorage(storage);

    // Some Windows USB card readers do not reliably appear in
    // mountedVolumes() immediately. QDir::drives() gives us a second view of
    // mounted drive roots; constructing QStorageInfo from each drive catches
    // those readers after insertion without requiring an app restart.
    for (const QFileInfo &drive : QDir::drives())
        considerStorage(QStorageInfo(drive.absoluteFilePath()));

    m_storageVolumes = volumes;
    emit storageVolumesChanged();

    // If the previously selected PC-reader card disappeared, clear the stale
    // right-hand directory instead of continuing to show files from an old
    // drive letter.
    bool currentRootStillMounted = m_musicVolumeRoot.isEmpty();
    for (const QVariant &entry : m_storageVolumes) {
        const QString root = entry.toMap().value(QStringLiteral("root")).toString();
        if (QString::compare(QDir::cleanPath(root),
                             QDir::cleanPath(m_musicVolumeRoot),
                             Qt::CaseInsensitive) == 0) {
            currentRootStillMounted = true;
            break;
        }
    }
    if (!currentRootStillMounted)
        m_musicVolumeRoot.clear();
    refreshMusicDirectories(m_musicVolumeRoot);
}

void AppController::connectBoard(const QString &portLabel, int baudRate)
{
    const QString portName = portLabel.section(QRegularExpression(QStringLiteral("\\s+—\\s+")), 0, 0)
                                 .trimmed();
    m_serial.openPort(portName, baudRate);
}

void AppController::disconnectBoard()
{
    m_serial.closePort();
}

void AppController::boardPlay()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    m_serial.sendCommand(SerialLink::Play);
    m_boardMotionTicks = 12;
    setToast(QStringLiteral("已发送板端播放命令。"));
}

void AppController::boardPause()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    m_serial.sendCommand(SerialLink::Pause);
    setToast(QStringLiteral("已发送板端暂停命令。"));
}

void AppController::boardPrevious()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    // Let FPGA apply the active playback mode. In random mode a direct
    // SelectTrack here would force sequential playback and bypass the mode.
    m_serial.sendCommand(SerialLink::Previous);
    setToast(QStringLiteral("已发送板端上一首命令。"));
}

void AppController::boardNext()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    m_serial.sendCommand(SerialLink::Next);
    setToast(QStringLiteral("已发送板端下一首命令。"));
}

void AppController::boardSelectSource(int source)
{
    const int bounded = qBound(0, source, 2);
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }

    if (bounded == 2) {
        // LINE IN is a real analog path. Keep the PC player on the current
        // Windows default output so the 3.5-mm cable sees the same signal as
        // other players. UART only changes the FPGA/codec routing.
        const QAudioDevice defaultOutput = QMediaDevices::defaultAudioOutput();
        if (!defaultOutput.isNull())
            m_audioOutput.setDevice(defaultOutput);
        m_audioOutput.setMuted(false);
        if (!m_pcAudioEnabled) {
            m_pcAudioEnabled = true;
            emit pcAudioEnabledChanged();
        }
    }

    const int currentSource =
        m_boardStatus.value(QStringLiteral("source"), -1).toInt();

    // Do not reset the whole FPGA media pipeline when a page asks for the
    // source that is already active. Repeated SelectSource frames were the
    // main cause of short mute windows while moving between Board/Playing/
    // External pages. A plain PLAY is enough to clear a stale pause.
    if (currentSource == bounded) {
        m_serial.sendCommand(SerialLink::Play);
        QTimer::singleShot(120, this, [this] {
            if (m_serial.boardOnline())
                m_serial.sendCommand(SerialLink::QueryStatus);
        });
        setToast(bounded == 0 ? QStringLiteral("板端已在TF卡模式，已恢复播放。")
                 : bounded == 1 ? QStringLiteral("板端已在QSFLASH模式，已恢复播放。")
                                : QStringLiteral("板端已在电脑LINE IN模式，保持直通输出。"));
        return;
    }

    sendVerifiedBoardCommand(SerialLink::SelectSource,
                             QByteArray(1, char(bounded)),
                             QStringLiteral("source"), bounded,
                             bounded == 0 ? QStringLiteral("切换到TF卡")
                             : bounded == 1 ? QStringLiteral("切换到QSFLASH")
                                            : QStringLiteral("切换到电脑LINE IN"));

    // SelectSource itself clears pause and restarts the requested pipeline.
    // Do NOT immediately send PLAY here: on TF that can arrive while FAT/RAW
    // is still mounting and cause a second media reset. Only use PLAY as a
    // delayed recovery when the new source is confirmed but still not running.
    const quint64 sourceTicket =
        m_controlTickets.value(QStringLiteral("source"), 0);
    QTimer::singleShot(700, this, [this, bounded, sourceTicket] {
        if (!m_serial.boardOnline()
            || m_controlTickets.value(QStringLiteral("source"), 0) != sourceTicket)
            return;
        if (m_boardStatus.value(QStringLiteral("source"), -1).toInt() != bounded) {
            m_serial.sendCommand(SerialLink::QueryStatus);
            return;
        }
        const int state = m_boardStatus.value(QStringLiteral("state"), 0).toInt();
        const int error = m_boardStatus.value(QStringLiteral("error"), 0).toInt();
        if (state != 1 && error == 0)
            m_serial.sendCommand(SerialLink::Play);
    });

    QTimer::singleShot(1050, this, [this, bounded, sourceTicket] {
        if (!m_serial.boardOnline()
            || m_controlTickets.value(QStringLiteral("source"), 0) != sourceTicket
            || m_boardStatus.value(QStringLiteral("source"), -1).toInt() != bounded)
            return;
        const int error = m_boardStatus.value(QStringLiteral("error"), 0).toInt();
        if (bounded == 1 && error != 0)
            setToast(boardErrorDescription(error));
        else if (bounded == 2 && boardExternalSignalKnown()
                 && !boardExternalSignal())
            setToast(QStringLiteral(
                "板端已进入电脑LINE IN，但暂未检测到输入。请确认3.5 mm线连接电脑音频输出与核心板LINE_IN，并确认Windows正在向该输出设备播放。"));
        else if (bounded == 2 && !boardExternalSignalKnown())
            setToast(QStringLiteral(
                "板端已进入电脑LINE IN；当前状态协议不回传输入检测位，请直接用PHONE OUT/扬声器试听。"));
    });
}

void AppController::boardSelectTrack(int track)
{
    const int bounded = qBound(0, track, 14);
    sendVerifiedBoardCommand(SerialLink::SelectTrack,
                             QByteArray(1, char(bounded)),
                             QStringLiteral("track"), bounded,
                             QStringLiteral("选择曲目%1").arg(bounded));
}

void AppController::boardSetPlaybackMode(int mode)
{
    const int bounded = qBound(0, mode, 3);
    sendVerifiedBoardCommand(SerialLink::SetPlayMode,
                             QByteArray(1, char(bounded)),
                             QStringLiteral("playMode"), bounded,
                             QStringLiteral("设置板端播放模式"));
}

void AppController::boardSeekMs(qint64 milliseconds)
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    quint32 value = static_cast<quint32>(qBound<qint64>(0, milliseconds, 0xffff'ffffLL));
    QByteArray payload;
    payload.resize(4);
    qToLittleEndian(value, reinterpret_cast<uchar *>(payload.data()));
    m_serial.sendCommand(SerialLink::Seek, payload);
    setToast(QStringLiteral("已请求跳转到 %1。").arg(formatTime(value)));
}

void AppController::boardSaveResume()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    m_serial.sendCommand(SerialLink::SaveResume);
    setToast(QStringLiteral("正在把当前歌曲和播放位置保存到QSFLASH。"));
}

void AppController::boardRestoreResume()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    m_serial.sendCommand(SerialLink::RestoreResume);
    setToast(QStringLiteral("已请求从QSFLASH恢复上次歌曲和播放位置。"));
}

void AppController::boardSetVolume(int percent)
{
    const int bounded = qBound(0, percent, 100);
    if (m_boardVolume != bounded) {
        m_boardVolume = bounded;
        emit boardStatusChanged();
    }
    if (!m_serial.boardOnline())
        return;
    // Keep the local slider authoritative briefly while the UART/FPGA status
    // pipeline catches up. This prevents stale STATUS packets from making a
    // long drag visibly jump backwards.
    m_ignoreBoardVolumeStatusUntil = QDateTime::currentMSecsSinceEpoch() + 450;
    m_serial.sendCommand(SerialLink::SetVolume, QByteArray(1, char(bounded)));
}

void AppController::boardSetTone(int percent)
{
    const int bounded = qBound(0, percent, 100);
    if (m_boardTone != bounded) {
        m_boardTone = bounded;
        emit boardStatusChanged();
    }
    if (!m_serial.boardOnline())
        return;
    m_ignoreBoardToneStatusUntil = QDateTime::currentMSecsSinceEpoch() + 450;
    m_serial.sendCommand(SerialLink::SetTone, QByteArray(1, char(bounded)));
}

void AppController::boardSetSpeaker(bool enabled)
{
    if (m_boardSpeakerEnabled != enabled) {
        m_boardSpeakerEnabled = enabled;
        emit boardStatusChanged();
    }
    sendVerifiedBoardCommand(SerialLink::SetSpeaker,
                             QByteArray(1, char(enabled ? 1 : 0)),
                             QStringLiteral("speakerEnabled"), enabled ? 1 : 0,
                             enabled ? QStringLiteral("开启板载扬声器")
                                     : QStringLiteral("关闭板载扬声器"));
}

void AppController::boardCopySdDemoToQspi()
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    if (boardSdReadyKnown() && !boardSdReady()) {
        setToast(QStringLiteral(
            "板载TF卡尚未就绪；请先让当前歌曲从TF卡正常播放，再截取到QSFLASH。"));
        return;
    }
    if (m_boardStatus.value(QStringLiteral("source"), 0).toInt() != 0) {
        setToast(QStringLiteral("请先切换到TF卡并播放到想截取的位置。"));
        return;
    }
    if (m_serial.uploadActive()) {
        setToast(QStringLiteral("请等待板载TF卡上传完成后再写QSFLASH。"));
        return;
    }
    if (qspiCopyBusy()) {
        setToast(QStringLiteral("QSFLASH正在写入，请等待完成。"));
        return;
    }

    m_qspiCopyRequested = true;
    m_qspiCopySeenActive = false;
    emit boardStatusChanged();
    setToast(QStringLiteral(
        "正在从当前歌曲的当前播放位置截取后续10秒并写入QSFLASH，请勿断电。"));
    m_serial.sendCommand(SerialLink::CopySdDemoToQspi);
    QTimer::singleShot(180, this, [this] {
        if (m_qspiCopyRequested && !m_qspiCopySeenActive
            && m_serial.boardOnline())
            m_serial.sendCommand(SerialLink::CopySdDemoToQspi);
    });
    QTimer::singleShot(250, this, [this] {
        if (m_serial.boardOnline())
            m_serial.sendCommand(SerialLink::QueryStatus);
    });
    QTimer::singleShot(2500, this, [this] {
        if (!m_qspiCopyRequested || m_qspiCopySeenActive)
            return;
        if (!m_boardStatus.value(
                QStringLiteral("extendedStatus"), false).toBool())
            return;
        m_qspiCopyRequested = false;
        emit boardStatusChanged();
        setToast(QStringLiteral(
            "FPGA未启动QSFLASH写入；请重新下载包含0x19远程KEY3命令的新bitstream。"));
    });
    QTimer::singleShot(12000, this, [this] {
        if (!m_qspiCopyRequested || m_qspiCopySeenActive
            || m_boardStatus.value(
                QStringLiteral("extendedStatus"), false).toBool())
            return;
        m_qspiCopyRequested = false;
        emit boardStatusChanged();
        setToast(QStringLiteral(
            "QSFLASH截取命令等待已结束。旧版状态不能回传结果，现尝试切换到QSFLASH播放。"));
        boardSelectSource(1);
    });
    QTimer::singleShot(120000, this, [this] {
        if (!m_qspiCopyRequested)
            return;
        m_qspiCopyRequested = false;
        m_qspiCopySeenActive = false;
        emit boardStatusChanged();
        setToast(QStringLiteral(
            "等待QSFLASH写入结果超时。请确认已下载包含0x19命令的新bitstream。"));
    });
}

void AppController::buildPackage(int slot, const QString &volumeRoot)
{
    beginPackageBuild(slot, volumeRoot, false);
}

void AppController::buildPackageToBoard(int boardTrack)
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    if (boardSdReadyKnown() && !boardSdReady()) {
        setToast(QStringLiteral("板载TF卡未就绪，无法上传RAW。"));
        return;
    }
    const int normalizedTrack = normalizeUserBoardTrack(boardTrack);
    if (normalizedTrack < 0 || normalizedTrack > 14) {
        setToast(QStringLiteral("板载RAW上传目标必须是曲目0到14。"));
        return;
    }
    if (m_serial.uploadActive()) {
        setToast(QStringLiteral("板载TF卡正在执行其他写入任务。"));
        return;
    }

    m_lastBoardUploadTrack = normalizedTrack;
    beginPackageBuild(normalizedTrack, QString(), true);
}

void AppController::beginPackageBuild(int slot, const QString &volumeRoot,
                                      bool uploadToBoard)
{
    if (m_busy) {
        setToast(QStringLiteral("请等待当前任务完成。"));
        return;
    }
    if (m_mp3Path.isEmpty() || m_lrcPath.isEmpty()) {
        setToast(QStringLiteral("必须同时选择MP3和对应LRC。"));
        return;
    }
    parseLyrics();
    if (!m_lrcResult.ok) {
        setToast(m_lrcResult.error);
        return;
    }

    m_pendingSlot = qBound(0, slot, 14);
    m_pendingVolumeRoot = QDir::fromNativeSeparators(volumeRoot);
    m_uploadToBoardAfterBuild = uploadToBoard;
    // The next build may replace the same USRxx.RAW path.  Until the worker
    // finishes and supplies a fresh size/CRC, force any manual upload path to
    // verify the file again instead of reusing stale metadata.
    m_generatedPackageBytes = 0;
    m_generatedPackageCrc32 = 0;
    if (!m_pendingVolumeRoot.isEmpty()) {
        QString error;
        if (!validateVolume(m_pendingVolumeRoot, 8ULL * 1024ULL * 1024ULL, &error)) {
            m_uploadToBoardAfterBuild = false;
            setToast(error);
            return;
        }
    }

    setTaskState(true, 0.0, QStringLiteral("开始转换MP3…"));
    m_converter.start(QUrl::fromLocalFile(QDir::fromNativeSeparators(m_mp3Path)));
}

void AppController::initializeSdSlots(const QString &volumeRoot, int slotCount)
{
    if (m_busy) {
        setToast(QStringLiteral("请等待当前任务完成。"));
        return;
    }
    const QString root = QDir::fromNativeSeparators(volumeRoot);
    const int count = qBound(1, slotCount, 10);
    QString error;
    if (!validateVolume(root, 1ULL * 1024ULL * 1024ULL, &error)) {
        setToast(error);
        return;
    }
    m_pendingVolumeRoot = root;
    m_pendingSlotCount = count;
    m_taskAction = TaskAction::InitializeSlots;
    setTaskState(true, 0.0, QStringLiteral("正在建立RAW歌曲槽文件…"));
    const QPointer<AppController> guard(this);
    const auto progress = [guard](double value, const QString &stage) {
        if (guard)
            guard->reportWorkerProgress(value, stage);
    };
    m_worker.setFuture(QtConcurrent::run([root, count, progress] {
        try {
            return SongPackage::initializeSdSlots(root, count,
                                                  SongPackage::DefaultSlotBytes,
                                                  progress);
        } catch (...) {
            return currentTaskException(QStringLiteral("初始化TF卡歌曲槽"));
        }
    }));
}

void AppController::uploadGeneratedPackage(int boardTrack)
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }
    const int normalizedTrack = normalizeUserBoardTrack(boardTrack);
    if (normalizedTrack < 0 || normalizedTrack > 14) {
        setToast(QStringLiteral("板载RAW上传目标必须是曲目0到14。"));
        return;
    }
    if (m_serial.uploadActive()) {
        setToast(QStringLiteral("板载TF卡正在执行其他写入任务。"));
        return;
    }
    if (m_generatedPackagePath.isEmpty()
        || !QFileInfo::exists(m_generatedPackagePath)) {
        setToast(QStringLiteral("请先生成RAW音频。"));
        return;
    }

    m_lastBoardUploadTrack = normalizedTrack;
    m_uploadToBoardAfterBuild = false;
    m_serial.uploadPackage(m_generatedPackagePath, normalizedTrack,
                           m_generatedPackageBytes,
                           m_generatedPackageCrc32);
}

void AppController::cancelCurrentTask()
{
    if (m_serial.uploadActive()) {
        m_serial.cancelUpload();
        setTaskState(false, 0.0, QStringLiteral("板载TF卡上传已取消"));
        setToast(QStringLiteral("已取消串口上传。"));
        return;
    }
    if (m_converter.rawPath().isEmpty())
        return;
    m_converter.cancel();
    m_uploadToBoardAfterBuild = false;
    setTaskState(false, 0.0, QStringLiteral("任务已取消"));
}

void AppController::restartSystemAudioMonitor()
{
    m_systemAudioMonitor.stop();
    m_systemAudioStatus = QStringLiteral("正在重新启动系统音频监视…");
    m_systemAudioAvailable = false;
    emit systemAudioStatusChanged();
    m_systemAudioMonitor.start();
    setToast(QStringLiteral("Windows系统音频监视已重新启动。"));
}

QString AppController::formatTime(qint64 milliseconds) const
{
    const qint64 seconds = qMax<qint64>(0, milliseconds / 1000);
    return QStringLiteral("%1:%2")
        .arg(seconds / 60)
        .arg(seconds % 60, 2, 10, QLatin1Char('0'));
}

QString AppController::displayPath(const QString &path) const
{
    return path.isEmpty() ? QStringLiteral("尚未选择")
                          : QDir::toNativeSeparators(path);
}

QString AppController::userSlotFileName(int boardTrack) const
{
    return SongPackage::boardTrackFileName(qBound(0, boardTrack, 14));
}

QString AppController::boardErrorDescription(int code) const
{
    if (code == 0)
        return QStringLiteral("板端无错误");
    if (m_serial.status().contains(QStringLiteral("上传失败"))
        || m_serial.status().contains(QStringLiteral("错误码0x")))
        return m_serial.status();

    const int source = m_boardStatus.value(QStringLiteral("source"), 0).toInt();
    if (source == 1) {
        if (code == 0x01)
            return QStringLiteral(
                "QSFLASH音频片段无效。请在TF卡播放时点击“截取当前10秒到QSFLASH”，等待写入完成后再播放。" );
        return QStringLiteral("QSFLASH读取失败（错误码0x%1）。")
            .arg(code, 2, 16, QLatin1Char('0'));
    }
    switch (code) {
    case 0x01: return QStringLiteral("TF卡上没有可识别的FAT32卷。");
    case 0x02: return QStringLiteral("板端未能定位或创建RAW目标文件。新版固件会自动创建USRxx.RAW，无需拔卡初始化；请确认已烧录配套bitstream并刷新TF卡目录。");
    case 0x0C: return QStringLiteral("TF卡可用空间不足，或没有足够连续空闲簇用于创建RAW文件。");
    case 0x0D: return QStringLiteral("FPGA创建RAW文件时更新FAT表失败。");
    case 0x0E: return QStringLiteral("FPGA创建RAW文件时写入/校验根目录项失败。");
    case 0x03: return QStringLiteral("目标歌曲文件不存在。");
    case 0x04: return QStringLiteral("歌曲目录项无效。");
    case 0x05: return QStringLiteral("FAT文件链无效。");
    case 0x06: return QStringLiteral("TF卡底层读写失败。");
    case 0x07: return QStringLiteral("RAW歌曲文件无效。");
    case 0x08: return QStringLiteral("RAW模式歌词使用同名LRC侧文件。");
    case 0x09: return QStringLiteral("RAW音频CRC校验失败。");
    default:
        return QStringLiteral("板端错误码0x%1。")
            .arg(code, 2, 16, QLatin1Char('0'));
    }
}

void AppController::clearToast()
{
    if (m_toastMessage.isEmpty())
        return;
    m_toastMessage.clear();
    emit toastMessageChanged();
}

void AppController::parseLyrics()
{
    if (m_lrcPath.isEmpty())
        return;
    m_lrcResult = LrcParser::parseFile(
        QDir::fromNativeSeparators(m_lrcPath), m_title);
    m_lyricLines.clear();
    m_boardPreview.clear();
    if (m_lrcResult.ok) {
        for (const LrcEntry &entry : m_lrcResult.entries)
            m_lyricLines.push_back(entry.text);
        for (const BoardLyricPage &page : m_lrcResult.boardPages) {
            m_boardPreview.push_back(
                QStringLiteral("%1   %2  /  %3")
                    .arg(formatTime(page.timeMs),
                         page.previewLine1,
                         page.previewLine2));
        }
        if (!m_lrcResult.warning.isEmpty())
            setToast(m_lrcResult.warning);
    } else {
        setToast(m_lrcResult.error);
    }
    m_currentLyricIndex = -1;
    emit lyricsChanged();
    emit currentLyricChanged();
    emit currentBoardPreviewChanged();
}

void AppController::loadCompanionLibrary()
{
    const QDir mediaDir(QDir(QCoreApplication::applicationDirPath())
                            .filePath(QStringLiteral("media")));
    QFile manifest(mediaDir.filePath(QStringLiteral("playlist.json")));
    if (!manifest.open(QIODevice::ReadOnly)) {
        emit librarySongsChanged();
        return;
    }
    const QJsonDocument document = QJsonDocument::fromJson(manifest.readAll());
    if (!document.isArray()) {
        emit librarySongsChanged();
        return;
    }
    m_librarySongs.clear();
    for (const QJsonValue &value : document.array()) {
        const QJsonObject object = value.toObject();
        QVariantMap song;
        song.insert(QStringLiteral("title"), object.value(QStringLiteral("title")).toString());
        song.insert(QStringLiteral("artist"), object.value(QStringLiteral("artist")).toString());
        song.insert(QStringLiteral("mp3Path"), mediaDir.filePath(
            object.value(QStringLiteral("mp3")).toString()));
        song.insert(QStringLiteral("lrcPath"), mediaDir.filePath(
            object.value(QStringLiteral("lrc")).toString()));
        m_librarySongs.push_back(song);
    }
    emit librarySongsChanged();
    refreshMusicDirectories(m_musicVolumeRoot);
    if (!m_boardStatus.isEmpty()) {
        loadBoardLyrics(m_boardStatus.value(
                            QStringLiteral("source"), 0).toInt(),
                        m_boardStatus.value(
                            QStringLiteral("track"), 0).toInt());
    }
}

void AppController::loadBoardLyrics(int source, int track)
{
    m_loadedBoardLyricSource = source;
    m_loadedBoardLyricTrack = track;
    m_boardLrcResult = {};
    m_boardLyricLines.clear();
    m_boardCurrentLyricIndex = -1;
    m_boardLcdPageIndex = -1;
    m_boardLcdTrack = -1;

    if (source == 2) {
        m_boardLyricStatus = QStringLiteral(
            "电脑LINE IN模式不传送歌词；此处显示Windows音频动态。" );
        emit boardLyricsChanged();
        emit boardCurrentLyricChanged();
        return;
    }

    QString title;
    QString lrcPath;
    if (source == 1) {
        // QSFLASH now stores a 10-second excerpt captured from the current
        // TF-card position. Its player timeline starts at 0 ms, so reusing a
        // full-song PC LRC here would display the wrong lines.
        m_boardLyricStatus = QStringLiteral(
            "QSFLASH当前10秒片段；LCD1602显示片段提示，Qt不套用错误的整曲LRC。" );
        emit boardLyricsChanged();
        emit boardCurrentLyricChanged();
        return;
    } else if (track >= 0 && track <= 14) {
        // Every board track is now writable. Prefer the LRC mapping saved by
        // the most recent import/upload, including tracks 0..4. If a legacy
        // fixed track has never been overwritten, fall back to the bundled
        // library entry for that track.
        QSettings settings;
        settings.beginGroup(QStringLiteral("BoardLyrics"));
        settings.beginGroup(QString::number(track));
        title = settings.value(QStringLiteral("title")).toString();
        lrcPath = settings.value(QStringLiteral("lrcPath")).toString();
        settings.endGroup();
        settings.endGroup();

        if (lrcPath.isEmpty() && track == m_lastBoardUploadTrack
            && !m_lrcPath.isEmpty()) {
            title = m_title;
            lrcPath = m_lrcPath;
        }
        if (lrcPath.isEmpty() && track < m_librarySongs.size()) {
            const QVariantMap song = m_librarySongs.at(track).toMap();
            title = song.value(QStringLiteral("title")).toString();
            lrcPath = song.value(QStringLiteral("lrcPath")).toString();
        }
        m_boardLyricStatus = lrcPath.isEmpty()
            ? QStringLiteral(
                "曲目%1尚无本机LRC映射；请在歌曲导入页为该槽重新选择并生成。")
                  .arg(track)
            : QStringLiteral("板端曲目%1：%2（本机LRC映射）")
                  .arg(track).arg(title);
    } else {
        m_boardLyricStatus = QStringLiteral(
            "板端曲目%1没有对应的本机歌词文件。" ).arg(track);
    }

    const QString normalizedPath = QDir::fromNativeSeparators(lrcPath);
    if (normalizedPath.isEmpty() || !QFileInfo::exists(normalizedPath)) {
        if (!lrcPath.isEmpty()) {
            m_boardLyricStatus = QStringLiteral(
                "曲目%1的LRC映射文件已移动或删除，请重新选择。" ).arg(track);
        }
        emit boardLyricsChanged();
        emit boardCurrentLyricChanged();
        return;
    }

    m_boardLrcResult = LrcParser::parseFile(normalizedPath, title);
    for (const LrcEntry &entry : m_boardLrcResult.entries)
        m_boardLyricLines.push_back(entry.text);
    if (m_boardLyricLines.isEmpty()) {
        m_boardLyricStatus = m_boardLrcResult.error.isEmpty()
            ? QStringLiteral("该LRC没有有效的时间戳歌词。")
            : m_boardLrcResult.error;
    }
    emit boardLyricsChanged();
    emit boardCurrentLyricChanged();
}

void AppController::updateBoardLyricPosition(qint64 positionMs)
{
    int low = 0;
    int high = m_boardLrcResult.entries.size() - 1;
    int found = -1;
    while (low <= high) {
        const int middle = low + (high - low) / 2;
        if (m_boardLrcResult.entries.at(middle).timeMs <= positionMs) {
            found = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    if (found == m_boardCurrentLyricIndex)
        return;
    m_boardCurrentLyricIndex = found;
    emit boardCurrentLyricChanged();
}

void AppController::updateBoardLcdLyricPage(qint64 positionMs)
{
    if (!m_serial.boardOnline() || m_serial.uploadActive()
        || m_boardTfScanActive) {
        return;
    }

    const int source = m_boardStatus.value(
        QStringLiteral("source"), -1).toInt();
    const int track = m_boardStatus.value(
        QStringLiteral("track"), -1).toInt();
    if (source != 0 || track < 0 || track > 14) {
        if (m_boardLcdPageIndex != -2) {
            m_serial.sendCommand(SerialLink::ClearLcdLyricPage);
            m_boardLcdPageIndex = -2;
            m_boardLcdTrack = -1;
        }
        return;
    }

    const QVector<BoardLyricPage> &pages = m_boardLrcResult.boardPages;
    if (pages.isEmpty()) {
        if (m_boardLcdPageIndex != -2 || m_boardLcdTrack != track) {
            m_serial.sendCommand(SerialLink::ClearLcdLyricPage);
            m_boardLcdPageIndex = -2;
            m_boardLcdTrack = track;
        }
        return;
    }

    int low = 0;
    int high = pages.size() - 1;
    int found = 0;
    while (low <= high) {
        const int middle = low + (high - low) / 2;
        if (pages.at(middle).timeMs <= positionMs) {
            found = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    if (m_boardLcdTrack == track && m_boardLcdPageIndex == found)
        return;

    const BoardLyricPage &page = pages.at(found);
    QByteArray line1 = page.line1.leftJustified(
        BoardLyricPage::LcdColumns, ' ', true);
    QByteArray line2 = page.line2.leftJustified(
        BoardLyricPage::LcdColumns, ' ', true);
    QByteArray glyphs = page.glyphs.leftJustified(
        BoardLyricPage::GlyphBytes, char(0), true);

    QByteArray payload;
    payload.reserve(1 + BoardLyricPage::LcdColumns * 2
                    + BoardLyricPage::GlyphBytes);
    payload.append(char(track));
    payload.append(line1);
    payload.append(line2);
    payload.append(glyphs);
    m_serial.sendCommand(SerialLink::SetLcdLyricPage, payload);
    m_boardLcdTrack = track;
    m_boardLcdPageIndex = found;
}

void AppController::rememberBoardLyrics(int boardTrack)
{
    const int normalizedTrack = normalizeUserBoardTrack(boardTrack);
    if (normalizedTrack < 0 || normalizedTrack > 14)
        return;

    QString displayTitle = rawSongTitleFromMp3(m_mp3Path, m_title).trimmed();
    if (displayTitle.isEmpty())
        displayTitle = m_title.trimmed();

    QSettings settings;
    settings.beginGroup(QStringLiteral("BoardLyrics"));
    settings.beginGroup(QString::number(normalizedTrack));
    settings.setValue(QStringLiteral("title"), displayTitle);
    settings.setValue(QStringLiteral("artist"), m_artist);
    settings.setValue(QStringLiteral("mp3Path"), m_mp3Path);
    if (!m_lrcPath.isEmpty() && QFileInfo::exists(m_lrcPath))
        settings.setValue(QStringLiteral("lrcPath"), m_lrcPath);
    else
        settings.remove(QStringLiteral("lrcPath"));
    settings.endGroup();
    settings.endGroup();
    settings.sync();

    // Keep the board song picker synchronized immediately after a successful
    // serial upload. The following directory refresh confirms the RAW file,
    // but the uploaded MP3 filename can already replace the USRxx placeholder.
    if (normalizedTrack < m_boardTfMusicFiles.size()) {
        QVariantMap song = m_boardTfMusicFiles.at(normalizedTrack).toMap();
        song.insert(QStringLiteral("title"), displayTitle);
        song.insert(QStringLiteral("present"), true);
        song.insert(QStringLiteral("valid"), true);
        song.insert(QStringLiteral("error"), 0);
        m_boardTfMusicFiles[normalizedTrack] = song;
        emit boardTfDirectoryChanged();
    }

    if (m_boardStatus.value(QStringLiteral("source"), 0).toInt() == 0
        && m_boardStatus.value(QStringLiteral("track"), -1).toInt()
            == normalizedTrack) {
        m_loadedBoardLyricTrack = -1;
        loadBoardLyrics(0, normalizedTrack);
        updateBoardLyricPosition(m_boardStatus.value(
            QStringLiteral("playMs"), 0).toLongLong());
    }
}

int AppController::normalizeUserBoardTrack(int boardTrack) const
{
    // The UI and UART protocol now both use the real board track number 0..14.
    return boardTrack;
}

void AppController::updateCurrentLyric(qint64 positionMs)
{
    int low = 0;
    int high = m_lrcResult.entries.size() - 1;
    int found = -1;
    while (low <= high) {
        const int middle = low + (high - low) / 2;
        if (m_lrcResult.entries.at(middle).timeMs <= positionMs) {
            found = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    if (found != m_currentLyricIndex) {
        m_currentLyricIndex = found;
        emit currentLyricChanged();
    }
}

void AppController::setTaskState(bool busy, double progress,
                                 const QString &status)
{
    m_busy = busy;
    m_taskProgress = qBound(0.0, progress, 1.0);
    m_taskStatus = status;
    emit taskChanged();
}

void AppController::setToast(const QString &message)
{
    m_toastMessage = message;
    emit toastMessageChanged();
}

void AppController::startPackageWorker(const QString &rawPath,
                                       qint64 durationMs)
{
    if (m_worker.isRunning()) {
        const QString error = QStringLiteral("后台任务尚未结束，请稍后重试。");
        m_uploadToBoardAfterBuild = false;
        setTaskState(false, 0.0, error);
        setToast(error);
        return;
    }
    QString documents = QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation);
    if (documents.isEmpty())
        documents = QDir::homePath();
    QDir rawDir(QDir(documents).filePath(QStringLiteral("GXMusicStudio/RAW")));
    rawDir.mkpath(QStringLiteral("."));

    QString rawBaseName = rawSongTitleFromMp3(m_mp3Path, m_title);
    if (rawBaseName.isEmpty())
        rawBaseName = QFileInfo(SongPackage::boardTrackFileName(m_pendingSlot)).completeBaseName();
    m_pendingPackagePath = rawDir.filePath(rawBaseName + QStringLiteral(".RAW"));

    const QString outputPath = m_pendingPackagePath;
    const QPointer<AppController> guard(this);
    const auto progress = [guard](double value, const QString &stage) {
        if (guard)
            guard->reportWorkerProgress(value, stage);
    };
    m_taskAction = TaskAction::BuildPackage;
    setTaskState(true, 0.79, QStringLiteral("正在生成44.1kHz / 16-bit / Stereo RAW…"));
    m_worker.setFuture(QtConcurrent::run(
        [outputPath, rawPath, durationMs, progress] {
            try {
                return SongPackage::create(outputPath, rawPath, {}, {}, {},
                                           durationMs, progress);
            } catch (...) {
                return currentTaskException(QStringLiteral("生成RAW音频"));
            }
        }));
}

void AppController::startCopyWorker(const QString &rawPath)
{
    const QString root = m_pendingVolumeRoot;
    const int track = m_pendingSlot;
    const QString lrcPath = QDir::fromNativeSeparators(m_lrcPath);
    const QString targetFileName = SongPackage::boardTrackFileName(track);
    const QString targetRaw = QDir(root).filePath(targetFileName);
    const qint64 existingBytes = QFileInfo(targetRaw).size();
    const qint64 rawBytes = QFileInfo(rawPath).size();
    const quint64 growth = rawBytes > existingBytes
        ? quint64(rawBytes - qMax<qint64>(0, existingBytes)) : 0ULL;
    const quint64 requiredBytes = growth
        + quint64(QFileInfo(lrcPath).size())
        + 2ULL * 1024ULL * 1024ULL;
    QString volumeError;
    if (!validateVolume(root, requiredBytes, &volumeError)) {
        setTaskState(false, 0.0, volumeError);
        setToast(volumeError);
        return;
    }
    const QPointer<AppController> guard(this);
    const auto progress = [guard](double value, const QString &stage) {
        if (guard)
            guard->reportWorkerProgress(value, stage);
    };
    m_taskAction = TaskAction::CopyToSd;
    m_worker.setFuture(QtConcurrent::run(
        [rawPath, root, track, lrcPath, progress] {
        try {
            PackageResult result = SongPackage::copyIntoBoardTrack(
                rawPath, root, track, progress);
            if (!result.ok)
                return result;

            const QString baseName = QFileInfo(
                SongPackage::boardTrackFileName(track)).completeBaseName();
            progress(0.98, QStringLiteral("正在写入同名LRC歌词…"));
            QString error;
            const QString rootLrc = QDir(root).filePath(baseName + QStringLiteral(".LRC"));
            if (!copyFileAtomically(lrcPath, rootLrc, &error)) {
                result.ok = false;
                result.error = error;
                return result;
            }

            progress(1.0, QStringLiteral("%1.RAW 与 %1.LRC 已写入TF卡根目录。")
                                 .arg(baseName));
            result.path = QDir(root).filePath(baseName + QStringLiteral(".RAW"));
            return result;
        } catch (...) {
            return currentTaskException(QStringLiteral("写入TF卡RAW文件"));
        }
    }));
}

void AppController::handleWorkerFinished()
{
    const TaskAction completedAction = m_taskAction;
    m_taskAction = TaskAction::None;
    PackageResult result;
    try {
        result = m_worker.result();
    } catch (...) {
        result = currentTaskException(QStringLiteral("后台任务"));
    }
    if (!result.ok) {
        m_uploadToBoardAfterBuild = false;
        setTaskState(false, 0.0, result.error);
        setToast(result.error);
        return;
    }

    if (completedAction == TaskAction::BuildPackage) {
        m_generatedPackagePath = result.path;
        m_generatedPackageBytes = result.fileBytes;
        m_generatedPackageCrc32 = result.fileCrc32;
        emit generatedPackageChanged();
        if (!m_pendingVolumeRoot.isEmpty()) {
            // Do not replace a QFuture on the same watcher from inside its
            // finished callback.  MinGW/Qt 6.11 can otherwise destroy the
            // previous result while the signal is still being delivered.
            const QString packagePath = result.path;
            QTimer::singleShot(0, this, [this, packagePath] {
                startCopyWorker(packagePath);
            });
            return;
        }
        if (m_uploadToBoardAfterBuild) {
            m_uploadToBoardAfterBuild = false;
            setTaskState(true, 1.0, QStringLiteral("RAW生成完成，准备板载TF卡上传…"));
            QTimer::singleShot(0, this, [this] {
                uploadGeneratedPackage(m_lastBoardUploadTrack);
            });
            return;
        }
        setTaskState(false, 1.0, QStringLiteral("RAW音频生成并校验完成"));
        setToast(QStringLiteral("RAW音频已生成：%1").arg(result.path));
    } else if (completedAction == TaskAction::CopyToSd) {
        rememberBoardLyrics(m_pendingSlot);
        setTaskState(false, 1.0, QStringLiteral("TF卡RAW与LRC写入完成"));
        const QString baseName = QFileInfo(
            SongPackage::boardTrackFileName(m_pendingSlot)).completeBaseName();
        setToast(QStringLiteral(
            "写入成功：TF卡根目录已有%1.RAW和%1.LRC。RAW为44.1kHz / 16-bit / Stereo纯PCM。请安全弹出TF卡。")
            .arg(baseName));
        refreshStorageVolumes();
    } else if (completedAction == TaskAction::InitializeSlots) {
        setTaskState(false, 1.0, QStringLiteral("RAW歌曲槽文件建立完成"));
        setToast(QStringLiteral("电脑端RAW用户槽已建立；新版板载固件也可在没有用户槽时自动创建RAW文件。"));
        refreshStorageVolumes();
    }
}

void AppController::sendVerifiedBoardCommand(SerialLink::Command command,
                                             const QByteArray &payload,
                                             const QString &statusKey,
                                             int expectedValue,
                                             const QString &actionName)
{
    if (!m_serial.boardOnline()) {
        setToast(QStringLiteral("请先连接核心板串口。"));
        return;
    }

    const quint64 ticket = m_controlTickets.value(statusKey, 0) + 1;
    m_controlTickets.insert(statusKey, ticket);

    // Send the control immediately.  TF-directory queries use the same UART
    // protocol and can postpone STATUS replies for several seconds, so a late
    // STATUS packet must never be interpreted as proof that the command was
    // rejected.  The FPGA side now accepts these controls even while a slot
    // query is in progress.
    m_serial.sendCommand(command, payload);
    setToast(QStringLiteral("%1命令已发送。").arg(actionName));

    const bool extendedOnly = statusKey == QStringLiteral("volume")
        || statusKey == QStringLiteral("tone")
        || statusKey == QStringLiteral("speakerEnabled");
    const bool mediaRestartCommand = statusKey == QStringLiteral("track")
        || statusKey == QStringLiteral("source");

    // Volume/tone/speaker are idempotent.  One short duplicate protects the
    // final slider value from a frame lost while the directory reader owns the
    // TF-card path.  Never duplicate source/track because those commands reset
    // the media pipeline.
    if (!mediaRestartCommand && extendedOnly) {
        QTimer::singleShot(90, this,
            [this, command, payload, statusKey, ticket] {
                if (!m_serial.boardOnline()
                    || m_controlTickets.value(statusKey) != ticket)
                    return;
                m_serial.sendCommand(command, payload);
            });
    }

    QTimer::singleShot(220, this, [this, statusKey, ticket] {
        if (m_serial.boardOnline()
            && m_controlTickets.value(statusKey) == ticket)
            m_serial.sendCommand(SerialLink::QueryStatus);
    });

    // Only call something "unconfirmed" when the board actually returned the
    // extended control fields.  Legacy/delayed STATUS frames do not contain
    // volume/tone/speaker feedback, so warning the user about an incompatible
    // bitstream was misleading and hid the fact that the command itself had
    // already been sent.
    QTimer::singleShot(950, this,
        [this, statusKey, expectedValue, actionName, ticket, extendedOnly] {
            if (!m_serial.boardOnline()
                || m_controlTickets.value(statusKey) != ticket)
                return;
            if (extendedOnly && !m_boardControlsConfirmed)
                return;
            if (m_boardStatus.value(statusKey, -1).toInt() != expectedValue)
                setToast(QStringLiteral("%1已发送，板端状态尚未同步；Qt将继续按当前设定值显示。")
                             .arg(actionName));
        });
}

void AppController::updateBoardVisualization(const QVariantMap &status)
{
    const int source = status.value(QStringLiteral("source"), 0).toInt();
    const int state = status.value(QStringLiteral("state"), 0).toInt();
    const int fifo = qBound(0, status.value(
        QStringLiteral("fifoPercent"), 0).toInt(), 100);
    const bool levelsKnown = status.value(
        QStringLiteral("levelsKnown"), false).toBool();

    // STATUS state is authoritative.  The old implementation advanced a
    // synthetic phase on every timer tick and also treated a non-empty FIFO as
    // playback, so a stopped board could show a moving spectrum forever.  A
    // frame is now active only while the board reports PLAYING; LINE IN also
    // needs an actual WASAPI signal before it is drawn.
    const bool boardOnline = m_serial.boardOnline();
    const bool active = boardOnline && state == 1
        && (source != 2 || m_systemAudioSignal);
    if (!active) {
        m_boardVisualizationActive = false;
        m_boardLeftLevel = 0.0;
        m_boardRightLevel = 0.0;
        m_boardSpectrum.fill(0.0);
        m_boardWaveform.fill(0.0);
        if (!boardOnline)
            m_boardVisualizationMode = QStringLiteral("BOARD OFFLINE");
        else if (source == 2)
            m_boardVisualizationMode = QStringLiteral("WAITING FOR PC AUDIO");
        else if (state == 2)
            m_boardVisualizationMode = QStringLiteral("PAUSED");
        else
            m_boardVisualizationMode = QStringLiteral("WAITING FOR PLAYBACK");
        emit boardVisualizationChanged();
        return;
    }

    m_boardVisualizationActive = true;
    // 33 ms frames are fast enough to feel live while leaving the GUI thread
    // headroom.  Keep the phase bounded so it cannot lose floating-point
    // precision after a long-running session.
    m_boardVisualPhase = std::fmod(
        m_boardVisualPhase + 0.24, 6.2831853071795864769);

    if (source == 2 && m_systemAudioSignal) {
        m_boardSpectrum = m_systemSpectrum;
        m_boardWaveform = m_systemWaveform;
        m_boardLeftLevel = m_systemLeftLevel;
        m_boardRightLevel = m_systemRightLevel;
        m_boardVisualizationMode = QStringLiteral("WINDOWS LOOPBACK");
        emit boardVisualizationChanged();
        return;
    }

    double left = levelsKnown
        ? qBound(0.0, status.value(
            QStringLiteral("leftLevel")).toDouble() / 255.0, 1.0)
        : 0.0;
    double right = levelsKnown
        ? qBound(0.0, status.value(
            QStringLiteral("rightLevel")).toDouble() / 255.0, 1.0)
        : 0.0;
    double energy = std::max(left, right);
    if ((!levelsKnown || energy < 0.008) && boardOnline) {
        const double fifoEnergy = qBound(0.0, double(fifo) / 100.0, 1.0);
        energy = qBound(0.0,
            (levelsKnown ? 0.08 : 0.22) + fifoEnergy * 0.26
                + 0.08 * std::sin(m_boardVisualPhase * 1.7), 0.86);
        left = qBound(0.0, energy * (0.88
            + 0.12 * std::sin(m_boardVisualPhase * 1.3)), 1.0);
        right = qBound(0.0, energy * (0.86
            + 0.14 * std::cos(m_boardVisualPhase * 1.1)), 1.0);
        m_boardVisualizationMode = levelsKnown
            ? QStringLiteral("PLAYBACK MOTION · LEVELS ZERO")
            : QStringLiteral("COMPATIBILITY ANIMATION");
    } else if (levelsKnown) {
        m_boardVisualizationMode = QStringLiteral("FPGA LEVEL-DRIVEN");
    }
    m_boardLeftLevel = left;
    m_boardRightLevel = right;

    QVariantList nextSpectrum;
    nextSpectrum.reserve(48);
    for (int index = 0; index < 48; ++index) {
        const double envelope = 0.22
            + 0.78 * std::abs(std::sin(index * 0.21
                                      + m_boardVisualPhase * 1.35));
        const double ripple = 0.50
            + 0.50 * std::abs(std::sin(index * 0.49
                                      - m_boardVisualPhase * 2.2));
        const double lowBias = 1.0 - 0.30 * double(index) / 47.0;
        const double target = qBound(0.0,
            energy * envelope * ripple * lowBias, 1.0);
        const double previous = index < m_boardSpectrum.size()
            ? m_boardSpectrum.at(index).toDouble() : 0.0;
        nextSpectrum.push_back(target > previous
            ? previous * 0.28 + target * 0.72
            : previous * 0.74 + target * 0.26);
    }
    m_boardSpectrum = nextSpectrum;

    QVariantList nextWaveform;
    nextWaveform.reserve(96);
    for (int index = 0; index < 96; ++index) {
        const double carrier = std::sin(index * 0.30
                                        + m_boardVisualPhase * 2.1);
        const double harmonic = 0.34 * std::sin(index * 0.71
                                                - m_boardVisualPhase * 1.2);
        nextWaveform.push_back((carrier + harmonic) * energy * 0.68);
    }
    m_boardWaveform = nextWaveform;
    emit boardVisualizationChanged();
}

void AppController::reportWorkerProgress(double value, const QString &stage)
{
    QMetaObject::invokeMethod(this, [this, value, stage] {
        setTaskState(true, value, stage);
    }, Qt::QueuedConnection);
}

bool AppController::validateVolume(const QString &root, quint64 requiredBytes,
                                   QString *error) const
{
    QStorageInfo storage(root);
    if (!storage.isValid() || !storage.isReady()) {
        *error = QStringLiteral("所选TF卡当前不可用。请重新插入并刷新。");
        return false;
    }
    const QString fs = QString::fromLatin1(storage.fileSystemType()).toUpper();
    if (fs != QStringLiteral("FAT32") && fs != QStringLiteral("VFAT")
        && fs != QStringLiteral("FAT")) {
        *error = QStringLiteral("所选盘不是FAT32，当前文件系统为%1。").arg(fs);
        return false;
    }
    if (storage.isReadOnly()) {
        *error = QStringLiteral("所选TF卡处于只读状态，请检查锁定开关。");
        return false;
    }
    if (storage.bytesAvailable() < static_cast<qint64>(requiredBytes)) {
        *error = QStringLiteral("TF卡剩余空间不足。");
        return false;
    }
    return true;
}
