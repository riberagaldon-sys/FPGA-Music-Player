#pragma once

#include <QObject>
#include <QMutex>
#include <QString>
#include <QThread>
#include <QTimer>
#include <QVariantList>

#include <atomic>

class SystemAudioMonitor final : public QObject
{
    Q_OBJECT

public:
    explicit SystemAudioMonitor(QObject *parent = nullptr);
    ~SystemAudioMonitor() override;

    void start();
    void stop();

signals:
    void analysisReady(const QVariantList &spectrum,
                       const QVariantList &waveform,
                       double leftLevel,
                       double rightLevel,
                       double peakLevel,
                       bool signalActive);
    void statusChanged(const QString &status, bool available);

private:
    void captureLoop();
    void queueAnalysis(const QVariantList &spectrum,
                       const QVariantList &waveform,
                       double leftLevel,
                       double rightLevel,
                       double peakLevel,
                       bool signalActive);
    void publishLatestAnalysis();

    std::atomic_bool m_captureRequested{false};
    QThread *m_thread = nullptr;
    QTimer m_publishTimer;
    QMutex m_frameMutex;
    QVariantList m_latestSpectrum;
    QVariantList m_latestWaveform;
    double m_latestLeftLevel = 0.0;
    double m_latestRightLevel = 0.0;
    double m_latestPeakLevel = 0.0;
    bool m_latestSignalActive = false;
    bool m_frameDirty = false;
};
