#include "AudioAnalyzer.h"

#include <QAudioFormat>
#include <QtMath>
#include <algorithm>
#include <cmath>
#include <complex>

namespace {
// 1024 samples at 44.1 kHz are about 23 ms.  This keeps the visual latency
// low enough for a responsive spectrum while still providing useful bass bins.
constexpr int kFftSize = 1024;
constexpr int kBarCount = 48;
constexpr int kWavePoints = 96;
constexpr double kPi = 3.14159265358979323846;
}

AudioAnalyzer::AudioAnalyzer(QObject *parent)
    : QObject(parent), m_smoothedBars(kBarCount, 0.0f)
{
    m_fftWindow.reserve(kFftSize * 2);
    m_emitClock.start();
}

void AudioAnalyzer::reset()
{
    m_fftWindow.clear();
    std::fill(m_smoothedBars.begin(), m_smoothedBars.end(), 0.0f);
    m_emitClock.restart();
    QVariantList spectrum;
    for (int i = 0; i < kBarCount; ++i)
        spectrum.push_back(0.0);
    QVariantList waveform;
    for (int i = 0; i < kWavePoints; ++i)
        waveform.push_back(0.0);
    emit analysisReady(spectrum, waveform, 0.0, 0.0, 0.0);
}

void AudioAnalyzer::consume(const QAudioBuffer &buffer)
{
    if (!buffer.isValid())
        return;
    const QAudioFormat format = buffer.format();
    const int channels = format.channelCount();
    const int bytesPerSample = format.bytesPerSample();
    const int bytesPerFrame = format.bytesPerFrame();
    if (channels < 1 || bytesPerSample < 1 || bytesPerFrame < 1)
        return;

    const char *data = buffer.constData<char>();
    const qsizetype frameCount = buffer.frameCount();
    QVector<float> mono;
    mono.reserve(frameCount);
    double leftSquare = 0.0;
    double rightSquare = 0.0;
    double peak = 0.0;

    for (qsizetype frame = 0; frame < frameCount; ++frame) {
        const char *framePtr = data + frame * bytesPerFrame;
        const float left = format.normalizedSampleValue(framePtr);
        const float right = channels > 1
            ? format.normalizedSampleValue(framePtr + bytesPerSample)
            : left;
        const float mixed = 0.5f * (left + right);
        mono.push_back(mixed);
        m_fftWindow.push_back(mixed);
        leftSquare += left * left;
        rightSquare += right * right;
        peak = std::max(peak,
                        std::max(std::abs(double(left)), std::abs(double(right))));
    }

    if (m_fftWindow.size() > kFftSize)
        m_fftWindow.remove(0, m_fftWindow.size() - kFftSize);
    if (m_fftWindow.size() < kFftSize || m_emitClock.elapsed() < 16)
        return;
    m_emitClock.restart();

    QVariantList waveform;
    for (int point = 0; point < kWavePoints; ++point) {
        const qsizetype index = m_fftWindow.isEmpty()
            ? 0
            : std::min<qsizetype>(m_fftWindow.size() - 1,
                                  (qint64(point) * m_fftWindow.size())
                                      / kWavePoints);
        waveform.push_back(m_fftWindow.isEmpty()
                               ? 0.0 : m_fftWindow.at(index));
    }

    const double divisor = std::max<qsizetype>(1, frameCount);
    const bool audible = peak >= 0.0025;
    const double leftRms = audible ? std::sqrt(leftSquare / divisor) : 0.0;
    const double rightRms = audible ? std::sqrt(rightSquare / divisor) : 0.0;
    QVariantList spectrum;
    if (audible) {
        spectrum = calculateSpectrum(m_fftWindow, format.sampleRate());
    } else {
        std::fill(m_smoothedBars.begin(), m_smoothedBars.end(), 0.0f);
        for (int index = 0; index < kBarCount; ++index)
            spectrum.push_back(0.0);
    }
    emit analysisReady(spectrum,
                       waveform,
                       qBound(0.0, leftRms * 2.4, 1.0),
                       qBound(0.0, rightRms * 2.4, 1.0),
                       audible ? qBound(0.0, peak, 1.0) : 0.0);
}

QVariantList AudioAnalyzer::calculateSpectrum(const QVector<float> &samples,
                                               int sampleRate)
{
    QVector<std::complex<float>> bins(kFftSize);
    for (int i = 0; i < kFftSize; ++i) {
        const float window = 0.5f
            - 0.5f * std::cos(float(2.0 * kPi * i / (kFftSize - 1)));
        bins[i] = std::complex<float>(samples.at(i) * window, 0.0f);
    }

    for (int i = 1, j = 0; i < kFftSize; ++i) {
        int bit = kFftSize >> 1;
        for (; j & bit; bit >>= 1)
            j ^= bit;
        j ^= bit;
        if (i < j)
            std::swap(bins[i], bins[j]);
    }
    for (int length = 2; length <= kFftSize; length <<= 1) {
        const float angle = float(-2.0 * kPi / length);
        const std::complex<float> step(std::cos(angle), std::sin(angle));
        for (int begin = 0; begin < kFftSize; begin += length) {
            std::complex<float> factor(1.0f, 0.0f);
            for (int offset = 0; offset < length / 2; ++offset) {
                const auto even = bins[begin + offset];
                const auto odd = factor * bins[begin + offset + length / 2];
                bins[begin + offset] = even + odd;
                bins[begin + offset + length / 2] = even - odd;
                factor *= step;
            }
        }
    }

    QVariantList output;
    for (int bar = 0; bar < kBarCount; ++bar) {
        const double lowHz = 28.0 * std::pow(18'000.0 / 28.0,
                                             double(bar) / kBarCount);
        const double highHz = 28.0 * std::pow(18'000.0 / 28.0,
                                              double(bar + 1) / kBarCount);
        const int lowBin = qBound(1, int(lowHz * kFftSize / sampleRate),
                                  kFftSize / 2 - 1);
        const int highBin = qBound(lowBin + 1,
                                   int(highHz * kFftSize / sampleRate) + 1,
                                   kFftSize / 2);
        float magnitude = 0.0f;
        for (int bin = lowBin; bin < highBin; ++bin)
            magnitude = std::max(magnitude, std::abs(bins.at(bin)));

        const double db = 20.0 * std::log10(
            std::max(1.0e-7, double(magnitude) / (kFftSize * 0.25)));
        const float normalized = float(qBound(0.0, (db + 66.0) / 66.0, 1.0));
        const float previous = m_smoothedBars.at(bar);
        const float smoothed = normalized > previous
            ? previous * 0.28f + normalized * 0.72f
            : previous * 0.74f + normalized * 0.26f;
        m_smoothedBars[bar] = smoothed;
        output.push_back(smoothed);
    }
    return output;
}
