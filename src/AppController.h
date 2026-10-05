#pragma once

#include "AudioAnalyzer.h"
#include "AudioConverter.h"
#include "LrcParser.h"
#include "SerialLink.h"
#include "SongPackage.h"
#include "SystemAudioMonitor.h"

#include <QAudioBufferOutput>
#include <QAudioOutput>
#include <QFutureWatcher>
#include <QHash>
#include <QMediaPlayer>
#include <QObject>
#include <QStringList>
#include <QTimer>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>

class AppController final : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool playing READ playing NOTIFY playbackChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(double volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(double playbackRate READ playbackRate WRITE setPlaybackRate
               NOTIFY playbackRateChanged)
    Q_PROPERTY(bool pcAudioEnabled READ pcAudioEnabled WRITE setPcAudioEnabled
               NOTIFY pcAudioEnabledChanged)
    Q_PROPERTY(QString title READ title WRITE setTitle NOTIFY metadataChanged)
    Q_PROPERTY(QString artist READ artist WRITE setArtist NOTIFY metadataChanged)
    Q_PROPERTY(QString mp3Path READ mp3Path NOTIFY importFilesChanged)
    Q_PROPERTY(QString lrcPath READ lrcPath NOTIFY importFilesChanged)
    Q_PROPERTY(QStringList lyricLines READ lyricLines NOTIFY lyricsChanged)
    Q_PROPERTY(int currentLyricIndex READ currentLyricIndex NOTIFY currentLyricChanged)
    Q_PROPERTY(QString currentLyric READ currentLyric NOTIFY currentLyricChanged)
    Q_PROPERTY(QString previousLyric READ previousLyric NOTIFY currentLyricChanged)
    Q_PROPERTY(QString nextLyric READ nextLyric NOTIFY currentLyricChanged)
    Q_PROPERTY(QString currentBoardPreview READ currentBoardPreview
               NOTIFY currentBoardPreviewChanged)
    Q_PROPERTY(QStringList boardPreview READ boardPreview NOTIFY lyricsChanged)
    Q_PROPERTY(QVariantList spectrum READ spectrum NOTIFY spectrumChanged)
    Q_PROPERTY(QVariantList waveform READ waveform NOTIFY waveformChanged)
    Q_PROPERTY(double leftLevel READ leftLevel NOTIFY levelsChanged)
    Q_PROPERTY(double rightLevel READ rightLevel NOTIFY levelsChanged)
    Q_PROPERTY(double peakLevel READ peakLevel NOTIFY levelsChanged)
    Q_PROPERTY(QVariantList boardSpectrum READ boardSpectrum
               NOTIFY boardVisualizationChanged)
    Q_PROPERTY(QVariantList boardWaveform READ boardWaveform
               NOTIFY boardVisualizationChanged)
    Q_PROPERTY(double boardLeftLevel READ boardLeftLevel
               NOTIFY boardVisualizationChanged)
    Q_PROPERTY(double boardRightLevel READ boardRightLevel
               NOTIFY boardVisualizationChanged)
    Q_PROPERTY(bool boardSdReady READ boardSdReady NOTIFY boardStatusChanged)
    Q_PROPERTY(bool boardSdReadyKnown READ boardSdReadyKnown
               NOTIFY boardStatusChanged)
    Q_PROPERTY(bool boardExternalSignal READ boardExternalSignal
               NOTIFY boardStatusChanged)
    Q_PROPERTY(bool boardExternalSignalKnown READ boardExternalSignalKnown
               NOTIFY boardStatusChanged)
    Q_PROPERTY(bool boardControlsConfirmed READ boardControlsConfirmed
               NOTIFY boardStatusChanged)
    Q_PROPERTY(int boardVolume READ boardVolume NOTIFY boardStatusChanged)
    Q_PROPERTY(int boardTone READ boardTone NOTIFY boardStatusChanged)
    Q_PROPERTY(bool boardSpeakerEnabled READ boardSpeakerEnabled
               NOTIFY boardStatusChanged)
    Q_PROPERTY(QStringList boardLyricLines READ boardLyricLines
               NOTIFY boardLyricsChanged)
    Q_PROPERTY(int boardCurrentLyricIndex READ boardCurrentLyricIndex
               NOTIFY boardCurrentLyricChanged)
    Q_PROPERTY(QString boardLyricStatus READ boardLyricStatus
               NOTIFY boardLyricsChanged)
    Q_PROPERTY(QString boardVisualizationMode READ boardVisualizationMode
               NOTIFY boardVisualizationChanged)
    Q_PROPERTY(bool boardVisualizationActive READ boardVisualizationActive
               NOTIFY boardVisualizationChanged)
    Q_PROPERTY(bool qspiCopyBusy READ qspiCopyBusy
               NOTIFY boardStatusChanged)
    Q_PROPERTY(int boardPlaybackMode READ boardPlaybackMode NOTIFY boardStatusChanged)
    Q_PROPERTY(qint64 boardDurationMs READ boardDurationMs NOTIFY boardStatusChanged)
    Q_PROPERTY(bool boardResumeValid READ boardResumeValid NOTIFY boardStatusChanged)
    Q_PROPERTY(QVariantList systemSpectrum READ systemSpectrum
               NOTIFY systemAudioChanged)
    Q_PROPERTY(QVariantList systemWaveform READ systemWaveform
               NOTIFY systemAudioChanged)
    Q_PROPERTY(double systemLeftLevel READ systemLeftLevel
               NOTIFY systemAudioChanged)
    Q_PROPERTY(double systemRightLevel READ systemRightLevel
               NOTIFY systemAudioChanged)
    Q_PROPERTY(double systemPeakLevel READ systemPeakLevel
               NOTIFY systemAudioChanged)
    Q_PROPERTY(bool systemAudioSignal READ systemAudioSignal
               NOTIFY systemAudioChanged)
    Q_PROPERTY(bool systemAudioAvailable READ systemAudioAvailable
               NOTIFY systemAudioStatusChanged)
    Q_PROPERTY(QString systemAudioStatus READ systemAudioStatus
               NOTIFY systemAudioStatusChanged)
    Q_PROPERTY(QStringList serialPorts READ serialPorts NOTIFY serialPortsChanged)
    Q_PROPERTY(QVariantList librarySongs READ librarySongs NOTIFY librarySongsChanged)
    Q_PROPERTY(int currentLibraryIndex READ currentLibraryIndex NOTIFY currentLibraryIndexChanged)
    Q_PROPERTY(int playbackMode READ playbackMode WRITE setPlaybackMode NOTIFY playbackModeChanged)
    Q_PROPERTY(QString playbackModeName READ playbackModeName NOTIFY playbackModeChanged)
    Q_PROPERTY(QVariantList localMusicFiles READ localMusicFiles NOTIFY musicDirectoriesChanged)
    Q_PROPERTY(QVariantList sdMusicFiles READ sdMusicFiles NOTIFY musicDirectoriesChanged)
    Q_PROPERTY(QVariantList boardTfMusicFiles READ boardTfMusicFiles NOTIFY boardTfDirectoryChanged)
    Q_PROPERTY(bool boardTfScanActive READ boardTfScanActive NOTIFY boardTfDirectoryChanged)
    Q_PROPERTY(QVariantList storageVolumes READ storageVolumes NOTIFY storageVolumesChanged)
    Q_PROPERTY(bool serialOpen READ serialOpen NOTIFY serialStateChanged)
    Q_PROPERTY(bool boardOnline READ boardOnline NOTIFY serialStateChanged)
    Q_PROPERTY(QString serialStatus READ serialStatus NOTIFY serialStateChanged)
    Q_PROPERTY(double serialUploadProgress READ serialUploadProgress
               NOTIFY serialStateChanged)
    Q_PROPERTY(bool serialUploadActive READ serialUploadActive NOTIFY serialStateChanged)
    Q_PROPERTY(QVariantMap boardStatus READ boardStatus NOTIFY boardStatusChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY taskChanged)
    Q_PROPERTY(double taskProgress READ taskProgress NOTIFY taskChanged)
    Q_PROPERTY(QString taskStatus READ taskStatus NOTIFY taskChanged)
    Q_PROPERTY(QString generatedPackagePath READ generatedPackagePath
               NOTIFY generatedPackageChanged)
    Q_PROPERTY(QString toastMessage READ toastMessage NOTIFY toastMessageChanged)

public:
    explicit AppController(QObject *parent = nullptr);
    ~AppController() override;

    bool playing() const;
    qint64 position() const { return m_player.position(); }
    qint64 duration() const { return m_player.duration(); }
    double volume() const { return m_audioOutput.volume(); }
    double playbackRate() const { return m_player.playbackRate(); }
    bool pcAudioEnabled() const { return m_pcAudioEnabled; }
    QString title() const { return m_title; }
    QString artist() const { return m_artist; }
    QString mp3Path() const { return m_mp3Path; }
    QString lrcPath() const { return m_lrcPath; }
    QStringList lyricLines() const { return m_lyricLines; }
    int currentLyricIndex() const { return m_currentLyricIndex; }
    QString currentLyric() const;
    QString previousLyric() const;
    QString nextLyric() const;
    QString currentBoardPreview() const;
    QStringList boardPreview() const { return m_boardPreview; }
    QVariantList spectrum() const { return m_spectrum; }
    QVariantList waveform() const { return m_waveform; }
    double leftLevel() const { return m_leftLevel; }
    double rightLevel() const { return m_rightLevel; }
    double peakLevel() const { return m_peakLevel; }
    QVariantList boardSpectrum() const { return m_boardSpectrum; }
    QVariantList boardWaveform() const { return m_boardWaveform; }
    double boardLeftLevel() const { return m_boardLeftLevel; }
    double boardRightLevel() const { return m_boardRightLevel; }
    bool boardSdReady() const;
    bool boardSdReadyKnown() const { return m_boardSdReadyKnown; }
    bool boardExternalSignal() const;
    bool boardExternalSignalKnown() const
    { return m_boardExternalSignalKnown; }
    bool boardControlsConfirmed() const { return m_boardControlsConfirmed; }
    int boardVolume() const { return m_boardVolume; }
    int boardTone() const { return m_boardTone; }
    bool boardSpeakerEnabled() const { return m_boardSpeakerEnabled; }
    QStringList boardLyricLines() const { return m_boardLyricLines; }
    int boardCurrentLyricIndex() const { return m_boardCurrentLyricIndex; }
    QString boardLyricStatus() const { return m_boardLyricStatus; }
    QString boardVisualizationMode() const { return m_boardVisualizationMode; }
    bool boardVisualizationActive() const { return m_boardVisualizationActive; }
    bool qspiCopyBusy() const;
    int boardPlaybackMode() const { return m_boardStatus.value(QStringLiteral("playMode"), 0).toInt(); }
    qint64 boardDurationMs() const { return m_boardStatus.value(QStringLiteral("totalMs"), 0).toLongLong(); }
    bool boardResumeValid() const { return m_boardStatus.value(QStringLiteral("resumeValid"), false).toBool(); }
    QVariantList systemSpectrum() const { return m_systemSpectrum; }
    QVariantList systemWaveform() const { return m_systemWaveform; }
    double systemLeftLevel() const { return m_systemLeftLevel; }
    double systemRightLevel() const { return m_systemRightLevel; }
    double systemPeakLevel() const { return m_systemPeakLevel; }
    bool systemAudioSignal() const { return m_systemAudioSignal; }
    bool systemAudioAvailable() const { return m_systemAudioAvailable; }
    QString systemAudioStatus() const { return m_systemAudioStatus; }
    QStringList serialPorts() const { return m_serialPorts; }
    QVariantList librarySongs() const { return m_librarySongs; }
    int currentLibraryIndex() const { return m_currentLibraryIndex; }
    int playbackMode() const { return m_playbackMode; }
    QString playbackModeName() const;
    QVariantList localMusicFiles() const { return m_localMusicFiles; }
    QVariantList sdMusicFiles() const { return m_sdMusicFiles; }
    QVariantList boardTfMusicFiles() const { return m_boardTfMusicFiles; }
    bool boardTfScanActive() const { return m_boardTfScanActive; }
    QVariantList storageVolumes() const { return m_storageVolumes; }
    bool serialOpen() const { return m_serial.isOpen(); }
    bool boardOnline() const { return m_serial.boardOnline(); }
    QString serialStatus() const { return m_serial.status(); }
    double serialUploadProgress() const { return m_serial.uploadProgress(); }
    bool serialUploadActive() const { return m_serial.uploadActive(); }
    QVariantMap boardStatus() const { return m_boardStatus; }
    bool busy() const { return m_busy; }
    double taskProgress() const { return m_taskProgress; }
    QString taskStatus() const { return m_taskStatus; }
    QString generatedPackagePath() const { return m_generatedPackagePath; }
    QString toastMessage() const { return m_toastMessage; }

    Q_INVOKABLE void setImportMp3(const QUrl &url);
    Q_INVOKABLE void setImportLrc(const QUrl &url);
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void stopPlayback();
    Q_INVOKABLE void seekNormalized(double ratio);
    Q_INVOKABLE void refreshSerialPorts();
    Q_INVOKABLE void loadLibrarySong(int index);
    Q_INVOKABLE void previousLocalSong();
    Q_INVOKABLE void nextLocalSong();
    Q_INVOKABLE void selectLocalSong(int index);
    Q_INVOKABLE void setPlaybackMode(int mode);
    Q_INVOKABLE void refreshMusicDirectories(const QString &volumeRoot = {});
    Q_INVOKABLE void deleteLocalMusicFile(const QString &path);
    Q_INVOKABLE void deleteSdSong(const QString &baseName, const QString &volumeRoot);
    Q_INVOKABLE void boardClearSlot(int boardTrack);
    Q_INVOKABLE void refreshBoardTfDirectory();
    Q_INVOKABLE void refreshStorageVolumes();
    Q_INVOKABLE void connectBoard(const QString &portName, int baudRate);
    Q_INVOKABLE void disconnectBoard();
    Q_INVOKABLE void boardPlay();
    Q_INVOKABLE void boardPause();
    Q_INVOKABLE void boardPrevious();
    Q_INVOKABLE void boardNext();
    Q_INVOKABLE void boardSelectSource(int source);
    Q_INVOKABLE void boardSelectTrack(int track);
    Q_INVOKABLE void boardSetVolume(int percent);
    Q_INVOKABLE void boardSetTone(int percent);
    Q_INVOKABLE void boardSetSpeaker(bool enabled);
    Q_INVOKABLE void boardCopySdDemoToQspi();
    Q_INVOKABLE void boardSetPlaybackMode(int mode);
    Q_INVOKABLE void boardSeekMs(qint64 milliseconds);
    Q_INVOKABLE void boardSaveResume();
    Q_INVOKABLE void boardRestoreResume();
    Q_INVOKABLE void buildPackage(int slot, const QString &volumeRoot = {});
    Q_INVOKABLE void buildPackageToBoard(int boardTrack);
    Q_INVOKABLE void initializeSdSlots(const QString &volumeRoot, int slotCount);
    Q_INVOKABLE void uploadGeneratedPackage(int boardTrack);
    Q_INVOKABLE void cancelCurrentTask();
    Q_INVOKABLE QString formatTime(qint64 milliseconds) const;
    Q_INVOKABLE QString displayPath(const QString &path) const;
    Q_INVOKABLE QString userSlotFileName(int boardTrack) const;
    Q_INVOKABLE QString boardErrorDescription(int code) const;
    Q_INVOKABLE void clearToast();
    Q_INVOKABLE void restartSystemAudioMonitor();

public slots:
    void setVolume(double volume);
    void setPlaybackRate(double rate);
    void setPcAudioEnabled(bool enabled);
    void setTitle(const QString &title);
    void setArtist(const QString &artist);

signals:
    void playbackChanged();
    void positionChanged();
    void durationChanged();
    void volumeChanged();
    void playbackRateChanged();
    void pcAudioEnabledChanged();
    void metadataChanged();
    void importFilesChanged();
    void lyricsChanged();
    void currentLyricChanged();
    void currentBoardPreviewChanged();
    void spectrumChanged();
    void waveformChanged();
    void levelsChanged();
    void boardVisualizationChanged();
    void boardLyricsChanged();
    void boardCurrentLyricChanged();
    void systemAudioChanged();
    void systemAudioStatusChanged();
    void serialPortsChanged();
    void librarySongsChanged();
    void currentLibraryIndexChanged();
    void playbackModeChanged();
    void musicDirectoriesChanged();
    void boardTfDirectoryChanged();
    void storageVolumesChanged();
    void serialStateChanged();
    void boardStatusChanged();
    void taskChanged();
    void generatedPackageChanged();
    void toastMessageChanged();

private:
    enum class TaskAction { None, BuildPackage, CopyToSd, InitializeSlots };

    void parseLyrics();
    void loadCompanionLibrary();
    void playLibraryIndex(int index, bool startPlayback);
    void advanceLocalAfterEnd();
    void updateCurrentLyric(qint64 positionMs);
    void setTaskState(bool busy, double progress, const QString &status);
    void setToast(const QString &message);
    void startPackageWorker(const QString &rawPath, qint64 durationMs);
    void startCopyWorker(const QString &packagePath);
    void handleWorkerFinished();
    void reportWorkerProgress(double value, const QString &stage);
    bool validateVolume(const QString &root, quint64 requiredBytes,
                        QString *error) const;
    void beginPackageBuild(int slot, const QString &volumeRoot,
                           bool uploadToBoard);
    void updateBoardVisualization(const QVariantMap &status);
    void loadBoardLyrics(int source, int track);
    void updateBoardLyricPosition(qint64 positionMs);
    void updateBoardLcdLyricPage(qint64 positionMs);
    void rememberBoardLyrics(int boardTrack);
    int normalizeUserBoardTrack(int boardTrack) const;
    void sendVerifiedBoardCommand(SerialLink::Command command,
                                  const QByteArray &payload,
                                  const QString &statusKey,
                                  int expectedValue,
                                  const QString &actionName);

    QAudioOutput m_audioOutput;
    QAudioBufferOutput m_bufferOutput;
    QMediaPlayer m_player;
    AudioAnalyzer m_analyzer;
    AudioConverter m_converter;
    SerialLink m_serial;
    SystemAudioMonitor m_systemAudioMonitor;
    QFutureWatcher<PackageResult> m_worker;

    QString m_title = QStringLiteral("GX Music Studio");
    QString m_artist = QStringLiteral("FPGA AUDIO SYSTEM");
    QString m_mp3Path;
    QString m_lrcPath;
    LrcParseResult m_lrcResult;
    QStringList m_lyricLines;
    QStringList m_boardPreview;
    int m_currentLyricIndex = -1;
    bool m_pcAudioEnabled = true;

    QVariantList m_spectrum;
    QVariantList m_waveform;
    double m_leftLevel = 0.0;
    double m_rightLevel = 0.0;
    double m_peakLevel = 0.0;
    QVariantList m_boardSpectrum;
    QVariantList m_boardWaveform;
    double m_boardLeftLevel = 0.0;
    double m_boardRightLevel = 0.0;
    double m_boardVisualPhase = 0.0;
    QString m_boardVisualizationMode = QStringLiteral("WAITING FOR BOARD");
    bool m_boardVisualizationActive = false;
    QTimer m_boardAnimationTimer;
    qint64 m_lastBoardPlayMs = -1;
    int m_boardMotionTicks = 0;
    bool m_boardSdReady = false;
    bool m_boardSdReadyKnown = false;
    bool m_boardExternalSignal = false;
    bool m_boardExternalSignalKnown = false;
    bool m_boardControlsConfirmed = false;
    int m_boardVolume = 100;
    int m_boardTone = 50;
    qint64 m_ignoreBoardVolumeStatusUntil = 0;
    qint64 m_ignoreBoardToneStatusUntil = 0;
    bool m_boardSpeakerEnabled = true;
    LrcParseResult m_boardLrcResult;
    QStringList m_boardLyricLines;
    int m_boardCurrentLyricIndex = -1;
    int m_loadedBoardLyricSource = -1;
    int m_loadedBoardLyricTrack = -1;
    int m_boardLcdPageIndex = -1;
    int m_boardLcdTrack = -1;
    QString m_boardLyricStatus = QStringLiteral("等待板端曲目信息");
    QVariantList m_systemSpectrum;
    QVariantList m_systemWaveform;
    double m_systemLeftLevel = 0.0;
    double m_systemRightLevel = 0.0;
    double m_systemPeakLevel = 0.0;
    bool m_systemAudioSignal = false;
    bool m_systemAudioAvailable = false;
    QString m_systemAudioStatus = QStringLiteral("正在启动系统音频监视…");

    QStringList m_serialPorts;
    QVariantList m_librarySongs;
    int m_currentLibraryIndex = -1;
    int m_playbackMode = 0; // 0 顺序, 1 单曲循环, 2 列表循环, 3 随机
    QVariantList m_localMusicFiles;
    QVariantList m_sdMusicFiles;
    QVariantList m_boardTfMusicFiles;
    bool m_boardTfScanActive = false;
    QString m_musicVolumeRoot;
    QVariantList m_storageVolumes;
    QVariantMap m_boardStatus;
    bool m_busy = false;
    double m_taskProgress = 0.0;
    QString m_taskStatus = QStringLiteral("等待操作");
    QString m_generatedPackagePath;
    QString m_toastMessage;
    TaskAction m_taskAction = TaskAction::None;
    int m_pendingSlot = 0;
    int m_pendingSlotCount = 1;
    QString m_pendingVolumeRoot;
    QString m_pendingPackagePath;
    quint64 m_generatedPackageBytes = 0;
    quint32 m_generatedPackageCrc32 = 0;
    bool m_uploadToBoardAfterBuild = false;
    int m_lastBoardUploadTrack = 5;
    bool m_qspiCopyRequested = false;
    bool m_qspiCopySeenActive = false;
    QHash<QString, quint64> m_controlTickets;
};
