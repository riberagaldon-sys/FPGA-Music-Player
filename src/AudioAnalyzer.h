#pragma once

#include <QAudioBuffer>
#include <QElapsedTimer>
#include <QObject>
#include <QVariantList>
#include <QVector>

class AudioAnalyzer final : public QObject
{
    Q_OBJECT

public:
    explicit AudioAnalyzer(QObject *parent = nullptr);
    void consume(const QAudioBuffer &buffer);
    void reset();

signals:
    void analysisReady(const QVariantList &spectrum,
                       const QVariantList &waveform,
                       double leftLevel,
                       double rightLevel,
                       double peakLevel);

private:
    QVariantList calculateSpectrum(const QVector<float> &samples,
                                   int sampleRate);

    QVector<float> m_fftWindow;
    QVector<float> m_smoothedBars;
    QElapsedTimer m_emitClock;
};

