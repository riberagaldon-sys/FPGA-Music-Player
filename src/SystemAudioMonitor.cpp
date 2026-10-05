#include "SystemAudioMonitor.h"

#include <QElapsedTimer>
#include <QMutexLocker>
#include <QVector>
#include <QtGlobal>

#include <algorithm>
#include <array>
#include <cmath>
#include <complex>
#include <cstdint>

#ifdef Q_OS_WIN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <audioclient.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#endif

namespace {
constexpr int kFftSize = 1024;
constexpr int kBarCount = 48;
constexpr int kWavePoints = 96;
// Keep analysis and presentation on the same 60-Hz cadence.  Computing FFTs
// faster than the UI can present them only wastes CPU and can starve QML's
// render thread on Debug builds.
constexpr int kAnalysisIntervalMs = 16;
constexpr int kPublishIntervalMs = 16;
constexpr double kPi = 3.14159265358979323846;

QVariantList zeroValues(int count)
{
    QVariantList values;
    values.reserve(count);
    for (int index = 0; index < count; ++index)
        values.push_back(0.0);
    return values;
}

#ifdef Q_OS_WIN
// MinGW 的 uuid 库在不同发行版中不一定包含这些 WASAPI GUID。
// 使用文件内常量可以避免链接阶段出现 undefined reference。
const CLSID kClsidMMDeviceEnumerator = {
    0xbcde0395, 0xe52f, 0x467c,
    {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}
};
const IID kIidIMMDeviceEnumerator = {
    0xa95664d2, 0x9614, 0x4f35,
    {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}
};
const IID kIidIAudioClient = {
    0x1cb9ad4c, 0xdbfa, 0x4c32,
    {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}
};
const IID kIidIAudioCaptureClient = {
    0xc8adbd64, 0xe71e, 0x48a0,
    {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}
};
const GUID kSubTypeIeeeFloat = {
    0x00000003, 0x0000, 0x0010,
    {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}
};
#endif

QVariantList makeSpectrum(const QVector<float> &samples,
                          QVector<float> &smoothed,
                          int sampleRate)
{
    QVariantList output;
    if (samples.size() < kFftSize || sampleRate <= 0) {
        for (int index = 0; index < kBarCount; ++index)
            output.push_back(0.0);
        return output;
    }

    // Window coefficients, bit-reversal indices and FFT roots never change.
    // The old implementation recalculated hundreds of sin/cos values for
    // every audio frame, which was the main source of external-page stutter.
    struct FftPlan {
        std::array<float, kFftSize> window{};
        std::array<int, kFftSize> reversed{};
        std::array<std::complex<float>, kFftSize / 2> roots{};

        FftPlan()
        {
            for (int index = 0; index < kFftSize; ++index) {
                window[index] = 0.5f - 0.5f * std::cos(
                    float(2.0 * kPi * index / (kFftSize - 1)));
                int source = index;
                int target = 0;
                for (int bit = 0; bit < 10; ++bit) {
                    target = (target << 1) | (source & 1);
                    source >>= 1;
                }
                reversed[index] = target;
            }
            for (int index = 0; index < kFftSize / 2; ++index) {
                const float angle = float(-2.0 * kPi * index / kFftSize);
                roots[index] = {std::cos(angle), std::sin(angle)};
            }
        }
    };
    static const FftPlan plan;

    std::array<std::complex<float>, kFftSize> bins{};
    const qsizetype base = samples.size() - kFftSize;
    for (int index = 0; index < kFftSize; ++index) {
        bins[plan.reversed[index]] = std::complex<float>(
            samples.at(base + index) * plan.window[index], 0.0f);
    }
    for (int length = 2; length <= kFftSize; length <<= 1) {
        const int rootStep = kFftSize / length;
        for (int begin = 0; begin < kFftSize; begin += length) {
            for (int offset = 0; offset < length / 2; ++offset) {
                const auto even = bins[begin + offset];
                const auto odd = plan.roots[offset * rootStep]
                    * bins[begin + offset + length / 2];
                bins[begin + offset] = even + odd;
                bins[begin + offset + length / 2] = even - odd;
            }
        }
    }

    if (smoothed.size() != kBarCount)
        smoothed.fill(0.0f, kBarCount);
    thread_local int mappedSampleRate = 0;
    thread_local std::array<int, kBarCount> lowBins{};
    thread_local std::array<int, kBarCount> highBins{};
    if (mappedSampleRate != sampleRate) {
        mappedSampleRate = sampleRate;
        for (int bar = 0; bar < kBarCount; ++bar) {
            const double lowHz = 28.0 * std::pow(
                18'000.0 / 28.0, double(bar) / kBarCount);
            const double highHz = 28.0 * std::pow(
                18'000.0 / 28.0, double(bar + 1) / kBarCount);
            lowBins[bar] = qBound(1, int(lowHz * kFftSize / sampleRate),
                                  kFftSize / 2 - 1);
            highBins[bar] = qBound(lowBins[bar] + 1,
                                   int(highHz * kFftSize / sampleRate) + 1,
                                   kFftSize / 2);
        }
    }
    for (int bar = 0; bar < kBarCount; ++bar) {
        float magnitude = 0.0f;
        for (int bin = lowBins[bar]; bin < highBins[bar]; ++bin)
            magnitude = std::max(magnitude, std::abs(bins[bin]));
        const double db = 20.0 * std::log10(
            std::max(1.0e-7, double(magnitude) / (kFftSize * 0.25)));
        const float value = float(qBound(0.0, (db + 66.0) / 66.0, 1.0));
        const float previous = smoothed.at(bar);
        smoothed[bar] = value > previous
            ? previous * 0.26f + value * 0.74f
            : previous * 0.72f + value * 0.28f;
        output.push_back(smoothed.at(bar));
    }
    return output;
}

QVariantList makeWaveform(const QVector<float> &samples)
{
    QVariantList output;
    output.reserve(kWavePoints);
    for (int point = 0; point < kWavePoints; ++point) {
        const qsizetype index = samples.isEmpty()
            ? 0
            : std::min<qsizetype>(samples.size() - 1,
                                  (qint64(point) * samples.size())
                                      / kWavePoints);
        output.push_back(samples.isEmpty() ? 0.0 : samples.at(index));
    }
    return output;
}

#ifdef Q_OS_WIN
float readSample(const BYTE *frame, int channel, int channels,
                 int bitsPerSample, bool floatingPoint)
{
    const int bytesPerSample = bitsPerSample / 8;
    const BYTE *sample = frame + qBound(0, channel, channels - 1)
        * bytesPerSample;
    if (floatingPoint && bitsPerSample == 32)
        return qBound(-1.0f, *reinterpret_cast<const float *>(sample), 1.0f);
    if (bitsPerSample == 16) {
        const qint16 value = qint16(quint16(sample[0])
                                   | (quint16(sample[1]) << 8));
        return float(value) / 32768.0f;
    }
    if (bitsPerSample == 24) {
        qint32 value = qint32(sample[0]) | (qint32(sample[1]) << 8)
            | (qint32(sample[2]) << 16);
        if (value & 0x0080'0000)
            value |= qint32(0xff00'0000);
        return float(value) / 8'388'608.0f;
    }
    if (bitsPerSample == 32) {
        const qint32 value = qint32(quint32(sample[0])
            | (quint32(sample[1]) << 8) | (quint32(sample[2]) << 16)
            | (quint32(sample[3]) << 24));
        return float(double(value) / 2'147'483'648.0);
    }
    if (bitsPerSample == 8)
        return (float(sample[0]) - 128.0f) / 128.0f;
    return 0.0f;
}
#endif
}

SystemAudioMonitor::SystemAudioMonitor(QObject *parent)
    : QObject(parent)
{
    m_latestSpectrum = zeroValues(kBarCount);
    m_latestWaveform = zeroValues(kWavePoints);
    m_publishTimer.setInterval(kPublishIntervalMs);
    m_publishTimer.setTimerType(Qt::PreciseTimer);
    connect(&m_publishTimer, &QTimer::timeout,
            this, &SystemAudioMonitor::publishLatestAnalysis);
}

SystemAudioMonitor::~SystemAudioMonitor()
{
    stop();
}

void SystemAudioMonitor::start()
{
    if (m_thread)
        return;
    {
        QMutexLocker locker(&m_frameMutex);
        m_latestSpectrum = zeroValues(kBarCount);
        m_latestWaveform = zeroValues(kWavePoints);
        m_latestLeftLevel = 0.0;
        m_latestRightLevel = 0.0;
        m_latestPeakLevel = 0.0;
        m_latestSignalActive = false;
        m_frameDirty = true;
    }
    m_publishTimer.start();
    m_captureRequested.store(true);
    m_thread = QThread::create([this] { captureLoop(); });
    m_thread->start();
}

void SystemAudioMonitor::stop()
{
    m_captureRequested.store(false);
    m_publishTimer.stop();
    if (!m_thread)
        return;
    m_thread->quit();
    // The capture loop waits at most 5 ms on the WASAPI event.  Never delete
    // the QThread wrapper until the worker has actually left the loop.
    if (!m_thread->wait(2000))
        m_thread->wait();
    delete m_thread;
    m_thread = nullptr;
}

void SystemAudioMonitor::queueAnalysis(const QVariantList &spectrum,
                                       const QVariantList &waveform,
                                       double leftLevel,
                                       double rightLevel,
                                       double peakLevel,
                                       bool signalActive)
{
    QMutexLocker locker(&m_frameMutex);
    // Replace the pending frame rather than queueing every capture callback.
    // If rendering briefly takes longer than 16 ms, the UI catches up on the
    // newest audio immediately instead of displaying an ever-growing backlog.
    m_latestSpectrum = spectrum;
    m_latestWaveform = waveform;
    m_latestLeftLevel = leftLevel;
    m_latestRightLevel = rightLevel;
    m_latestPeakLevel = peakLevel;
    m_latestSignalActive = signalActive;
    m_frameDirty = true;
}

void SystemAudioMonitor::publishLatestAnalysis()
{
    QVariantList spectrum;
    QVariantList waveform;
    double leftLevel = 0.0;
    double rightLevel = 0.0;
    double peakLevel = 0.0;
    bool signalActive = false;
    {
        QMutexLocker locker(&m_frameMutex);
        if (!m_frameDirty)
            return;
        spectrum = m_latestSpectrum;
        waveform = m_latestWaveform;
        leftLevel = m_latestLeftLevel;
        rightLevel = m_latestRightLevel;
        peakLevel = m_latestPeakLevel;
        signalActive = m_latestSignalActive;
        m_frameDirty = false;
    }
    emit analysisReady(spectrum, waveform, leftLevel, rightLevel,
                       peakLevel, signalActive);
}

void SystemAudioMonitor::captureLoop()
{
#ifndef Q_OS_WIN
    emit statusChanged(QStringLiteral("当前系统不支持Windows回环音频监视。"),
                       false);
    return;
#else
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool uninitialize = SUCCEEDED(result);
    IMMDeviceEnumerator *enumerator = nullptr;
    IMMDevice *device = nullptr;
    IAudioClient *client = nullptr;
    IAudioCaptureClient *capture = nullptr;
    WAVEFORMATEX *format = nullptr;
    HANDLE readyEvent = nullptr;

    auto fail = [this](const QString &message) {
        emit statusChanged(message, false);
    };

    result = CoCreateInstance(kClsidMMDeviceEnumerator, nullptr, CLSCTX_ALL,
                              kIidIMMDeviceEnumerator,
                              reinterpret_cast<void **>(&enumerator));
    if (FAILED(result)) {
        fail(QStringLiteral("无法打开Windows音频设备。"));
        goto cleanup;
    }
    result = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(result)) {
        fail(QStringLiteral("Windows没有默认播放设备。"));
        goto cleanup;
    }
    result = device->Activate(kIidIAudioClient, CLSCTX_ALL, nullptr,
                              reinterpret_cast<void **>(&client));
    if (FAILED(result) || FAILED(client->GetMixFormat(&format))) {
        fail(QStringLiteral("无法读取系统播放格式。"));
        goto cleanup;
    }

    readyEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
    if (!readyEvent) {
        fail(QStringLiteral("无法创建系统音频监视事件。"));
        goto cleanup;
    }
    result = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                AUDCLNT_STREAMFLAGS_LOOPBACK
                                    | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                                1'000'000, 0, format, nullptr);
    if (FAILED(result)
        || FAILED(client->SetEventHandle(readyEvent))
        || FAILED(client->GetService(kIidIAudioCaptureClient,
                                     reinterpret_cast<void **>(&capture)))
        || FAILED(client->Start())) {
        fail(QStringLiteral("系统音频回环启动失败，请确认默认扬声器可用。"));
        goto cleanup;
    }

    {
        bool floatingPoint = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
        if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE
            && format->cbSize >= 22) {
            const auto *extended = reinterpret_cast<WAVEFORMATEXTENSIBLE *>(format);
            floatingPoint = IsEqualGUID(extended->SubFormat,
                                        kSubTypeIeeeFloat);
        }
        const int channels = qMax(1, int(format->nChannels));
        const int bits = int(format->wBitsPerSample);
        const int bytesPerFrame = int(format->nBlockAlign);
        QVector<float> fftWindow;
        fftWindow.reserve(kFftSize * 2);
        QVector<float> recent;
        recent.reserve(kFftSize * 2);
        QVector<float> smoothed(kBarCount, 0.0f);
        double accumulatedLeftSquare = 0.0;
        double accumulatedRightSquare = 0.0;
        double accumulatedPeak = 0.0;
        quint64 accumulatedFrames = 0;
        QElapsedTimer emitClock;
        QElapsedTimer silenceClock;
        emitClock.start();
        silenceClock.start();
        emit statusChanged(QStringLiteral("正在监视Windows系统播放声音"), true);

        while (m_captureRequested.load()) {
            // A short wait allows the monitor to publish a silence frame soon
            // after a player pauses, instead of leaving the last bars frozen.
            WaitForSingleObject(readyEvent, 5);
            UINT32 packetFrames = 0;
            if (FAILED(capture->GetNextPacketSize(&packetFrames)))
                break;
            bool emittedThisWait = false;
            while (packetFrames > 0) {
                BYTE *data = nullptr;
                UINT32 frames = 0;
                DWORD flags = 0;
                if (FAILED(capture->GetBuffer(&data, &frames, &flags,
                                              nullptr, nullptr))) {
                    packetFrames = 0;
                    break;
                }
                double peak = 0.0;
                const bool silent = flags & AUDCLNT_BUFFERFLAGS_SILENT;
                for (UINT32 frameIndex = 0; frameIndex < frames; ++frameIndex) {
                    const BYTE *frame = data + frameIndex * bytesPerFrame;
                    const float left = silent ? 0.0f
                        : readSample(frame, 0, channels, bits, floatingPoint);
                    const float right = silent ? 0.0f
                        : readSample(frame, channels > 1 ? 1 : 0,
                                     channels, bits, floatingPoint);
                    const float mono = 0.5f * (left + right);
                    recent.push_back(mono);
                    fftWindow.push_back(mono);
                    accumulatedLeftSquare += double(left) * left;
                    accumulatedRightSquare += double(right) * right;
                    peak = std::max(peak, std::max(std::abs(double(left)),
                                                   std::abs(double(right))));
                }
                accumulatedPeak = std::max(accumulatedPeak, peak);
                accumulatedFrames += frames;
                capture->ReleaseBuffer(frames);
                if (fftWindow.size() > kFftSize * 2)
                    fftWindow.remove(0, fftWindow.size() - kFftSize * 2);

                const bool signalActive = accumulatedPeak >= 0.0015;
                if (signalActive)
                    silenceClock.restart();
                if (emitClock.elapsed() >= kAnalysisIntervalMs
                    && !recent.isEmpty()) {
                    emitClock.restart();
                    emittedThisWait = true;
                    const double divisor = double(qMax<quint64>(
                        1, accumulatedFrames));
                    const double left = qBound(0.0,
                        std::sqrt(accumulatedLeftSquare / divisor) * 2.4, 1.0);
                    const double right = qBound(0.0,
                        std::sqrt(accumulatedRightSquare / divisor) * 2.4, 1.0);
                    if (signalActive) {
                        queueAnalysis(
                            makeSpectrum(fftWindow, smoothed,
                                         format->nSamplesPerSec),
                            makeWaveform(recent), left, right,
                            qBound(0.0, accumulatedPeak, 1.0), true);
                    } else {
                        std::fill(smoothed.begin(), smoothed.end(), 0.0f);
                        queueAnalysis(zeroValues(kBarCount),
                                      zeroValues(kWavePoints),
                                      0.0, 0.0, 0.0, false);
                    }
                    recent.clear();
                    accumulatedLeftSquare = 0.0;
                    accumulatedRightSquare = 0.0;
                    accumulatedPeak = 0.0;
                    accumulatedFrames = 0;
                }
                if (FAILED(capture->GetNextPacketSize(&packetFrames)))
                    packetFrames = 0;
            }
            if (!emittedThisWait
                && emitClock.elapsed() >= kAnalysisIntervalMs
                && silenceClock.elapsed() >= 48) {
                emitClock.restart();
                silenceClock.restart();
                std::fill(smoothed.begin(), smoothed.end(), 0.0f);
                fftWindow.clear();
                recent.clear();
                accumulatedLeftSquare = 0.0;
                accumulatedRightSquare = 0.0;
                accumulatedPeak = 0.0;
                accumulatedFrames = 0;
                queueAnalysis(zeroValues(kBarCount),
                              zeroValues(kWavePoints),
                              0.0, 0.0, 0.0, false);
            }
        }
        client->Stop();
    }

cleanup:
    if (capture)
        capture->Release();
    if (client)
        client->Release();
    if (device)
        device->Release();
    if (enumerator)
        enumerator->Release();
    if (format)
        CoTaskMemFree(format);
    if (readyEvent)
        CloseHandle(readyEvent);
    if (uninitialize)
        CoUninitialize();
#endif
}
