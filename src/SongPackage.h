#pragma once

#include "LrcParser.h"

#include <QString>
#include <functional>

struct PackageResult
{
    bool ok = false;
    QString error;
    QString path;
    quint64 fileBytes = 0;
    quint32 fileCrc32 = 0;
};

class SongPackage
{
public:
    static constexpr quint32 HeaderBytes = 512;
    static constexpr quint32 AudioOffset = 0x0001'0000;
    // Legacy constants retained for source compatibility. RAW mode stores pure
    // 44.1 kHz / signed 16-bit / stereo / little-endian PCM without a header.
    static constexpr quint16 LyricRecordBytes = BoardLyricPage::RecordBytes;
    static constexpr quint64 DefaultSlotBytes = 96ULL * 1024ULL * 1024ULL;

    using Progress = std::function<void(double, const QString &)>;

    static PackageResult create(const QString &packagePath,
                                const QString &rawPath,
                                const QVector<BoardLyricPage> &pages,
                                const QString &title,
                                const QString &artist,
                                qint64 durationMs,
                                const Progress &progress = {});
    static PackageResult copyIntoSdSlot(const QString &packagePath,
                                        const QString &volumeRoot,
                                        int slot,
                                        const Progress &progress = {});
    static PackageResult copyIntoBoardTrack(const QString &packagePath,
                                            const QString &volumeRoot,
                                            int track,
                                            const Progress &progress = {});
    static PackageResult initializeSdSlots(const QString &volumeRoot,
                                           int slotCount,
                                           quint64 slotBytes = DefaultSlotBytes,
                                           const Progress &progress = {});
    static PackageResult verify(const QString &path,
                                const Progress &progress = {});
    static QString slotFileName(int slot);
    static QString boardTrackFileName(int track);
    static quint32 crc32File(const QString &path, bool *ok = nullptr);

private:
    static quint32 crc32Update(quint32 crc, const char *data, qsizetype size);
};
