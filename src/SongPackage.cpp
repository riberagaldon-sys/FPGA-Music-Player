#include "SongPackage.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QSaveFile>
#include <algorithm>

namespace {
bool copyFileExact(const QString &sourcePath, const QString &targetPath,
                   QString *error, const SongPackage::Progress &progress = {},
                   double progressBase = 0.0, double progressSpan = 1.0)
{
    QFile source(sourcePath);
    if (!source.open(QIODevice::ReadOnly)) {
        if (error) *error = QStringLiteral("无法读取RAW文件：%1").arg(source.errorString());
        return false;
    }

    QSaveFile target(targetPath);
    if (!target.open(QIODevice::WriteOnly)) {
        if (error) *error = QStringLiteral("无法创建RAW文件：%1").arg(target.errorString());
        return false;
    }

    const qint64 total = source.size();
    qint64 copied = 0;
    QByteArray block(256 * 1024, Qt::Uninitialized);
    while (!source.atEnd()) {
        const qint64 count = source.read(block.data(), block.size());
        if (count < 0) {
            target.cancelWriting();
            if (error) *error = QStringLiteral("读取RAW文件失败：%1").arg(source.errorString());
            return false;
        }
        if (count == 0)
            break;
        if (target.write(block.constData(), count) != count) {
            target.cancelWriting();
            if (error) *error = QStringLiteral("写入RAW文件失败：%1").arg(target.errorString());
            return false;
        }
        copied += count;
        if (progress && total > 0)
            progress(progressBase + progressSpan * double(copied) / double(total),
                     QStringLiteral("正在写入RAW音频…"));
    }

    if (!target.commit()) {
        if (error) *error = QStringLiteral("提交RAW文件失败：%1").arg(target.errorString());
        return false;
    }
    return true;
}
}

quint32 SongPackage::crc32Update(quint32 crc, const char *data, qsizetype size)
{
    for (qsizetype i = 0; i < size; ++i) {
        crc ^= static_cast<quint8>(data[i]);
        for (int bit = 0; bit < 8; ++bit)
            crc = (crc & 1U) ? ((crc >> 1) ^ 0xEDB88320U) : (crc >> 1);
    }
    return crc;
}

QString SongPackage::slotFileName(int slot)
{
    const int bounded = std::clamp(slot, 0, 9);
    return QStringLiteral("USR%1.RAW")
        .arg(bounded, 2, 10, QLatin1Char('0'));
}

QString SongPackage::boardTrackFileName(int track)
{
    const int bounded = std::clamp(track, 0, 14);
    switch (bounded) {
    case 0: return QStringLiteral("SONG.RAW");
    case 1: return QStringLiteral("BEAUTY.RAW");
    case 2: return QStringLiteral("DIE4YOU.RAW");
    case 3: return QStringLiteral("PAYPHONE.RAW");
    case 4: return QStringLiteral("STARBOY.RAW");
    default: return slotFileName(bounded - 5);
    }
}

quint32 SongPackage::crc32File(const QString &path, bool *ok)
{
    if (ok) *ok = false;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return 0;

    quint32 crc = 0xFFFF'FFFFU;
    QByteArray block(256 * 1024, Qt::Uninitialized);
    while (!file.atEnd()) {
        const qint64 count = file.read(block.data(), block.size());
        if (count < 0)
            return 0;
        if (count == 0)
            break;
        crc = crc32Update(crc, block.constData(), count);
    }
    if (ok) *ok = true;
    return crc ^ 0xFFFF'FFFFU;
}

PackageResult SongPackage::create(const QString &packagePath,
                                  const QString &rawPath,
                                  const QVector<BoardLyricPage> &,
                                  const QString &,
                                  const QString &,
                                  qint64,
                                  const Progress &progress)
{
    PackageResult result;
    QFileInfo sourceInfo(rawPath);
    if (!sourceInfo.exists() || sourceInfo.size() <= 0) {
        result.error = QStringLiteral("转换后的RAW音频为空。");
        return result;
    }
    if ((sourceInfo.size() & 3) != 0) {
        result.error = QStringLiteral("RAW长度不是4字节整数倍，无法作为16-bit双声道PCM播放。");
        return result;
    }

    QString error;
    if (!copyFileExact(rawPath, packagePath, &error, progress, 0.80, 0.18)) {
        result.error = error;
        return result;
    }

    result = verify(packagePath, progress);
    if (result.ok && progress)
        progress(1.0, QStringLiteral("RAW音频生成并校验完成。"));
    return result;
}

PackageResult SongPackage::copyIntoSdSlot(const QString &packagePath,
                                          const QString &volumeRoot,
                                          int slot,
                                          const Progress &progress)
{
    PackageResult sourceCheck = verify(packagePath);
    if (!sourceCheck.ok)
        return sourceCheck;

    PackageResult result;
    const QString targetPath = QDir(volumeRoot).filePath(slotFileName(slot));
    QString error;
    if (!copyFileExact(packagePath, targetPath, &error, progress, 0.90, 0.09)) {
        result.error = error;
        return result;
    }

    result = verify(targetPath, progress);
    if (result.ok && progress)
        progress(1.0, QStringLiteral("TF卡RAW文件写入并校验完成。"));
    return result;
}

PackageResult SongPackage::copyIntoBoardTrack(const QString &packagePath,
                                              const QString &volumeRoot,
                                              int track,
                                              const Progress &progress)
{
    PackageResult sourceCheck = verify(packagePath);
    if (!sourceCheck.ok)
        return sourceCheck;

    PackageResult result;
    const QString targetPath = QDir(volumeRoot).filePath(boardTrackFileName(track));
    QString error;
    if (!copyFileExact(packagePath, targetPath, &error, progress, 0.90, 0.09)) {
        result.error = error;
        return result;
    }

    result = verify(targetPath, progress);
    if (result.ok && progress)
        progress(1.0, QStringLiteral("TF卡RAW文件写入并校验完成。"));
    return result;
}

PackageResult SongPackage::initializeSdSlots(const QString &volumeRoot,
                                             int slotCount,
                                             quint64 slotBytes,
                                             const Progress &progress)
{
    PackageResult result;
    if (slotCount < 1 || slotCount > 10) {
        result.error = QStringLiteral("RAW歌曲槽数量无效。");
        return result;
    }

    QDir root(volumeRoot);
    if (!root.exists()) {
        result.error = QStringLiteral("TF卡根目录不存在。");
        return result;
    }

    for (int slot = 0; slot < slotCount; ++slot) {
        const QString path = root.filePath(slotFileName(slot));
        QFile file(path);
        if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
            result.error = QStringLiteral("无法创建%1：%2")
                               .arg(slotFileName(slot), file.errorString());
            return result;
        }
        // Allocate a persistent cluster chain once.  The FPGA later rewrites
        // the RAW bytes in place and only updates the FAT directory file-size
        // field, so a shorter song can later be replaced by a longer one.
        if (slotBytes == 0 || !file.resize(static_cast<qint64>(slotBytes))) {
            result.error = QStringLiteral("无法为%1预分配RAW槽空间：%2")
                               .arg(slotFileName(slot), file.errorString());
            file.close();
            return result;
        }
        file.close();
        if (progress)
            progress(double(slot + 1) / double(slotCount),
                     QStringLiteral("正在预分配RAW歌曲槽 %1/%2…")
                         .arg(slot + 1).arg(slotCount));
    }

    result.ok = true;
    result.path = volumeRoot;
    return result;
}

PackageResult SongPackage::verify(const QString &path,
                                  const Progress &progress)
{
    PackageResult result;
    QFileInfo info(path);
    if (!info.exists() || !info.isFile()) {
        result.error = QStringLiteral("RAW文件不存在。");
        return result;
    }
    if (info.size() <= 0) {
        result.error = QStringLiteral("RAW文件为空。");
        return result;
    }
    if ((info.size() & 3) != 0) {
        result.error = QStringLiteral("RAW文件长度不是4字节整数倍。");
        return result;
    }

    bool crcOk = false;
    const quint32 crc = crc32File(path, &crcOk);
    if (!crcOk) {
        result.error = QStringLiteral("RAW文件CRC计算失败。");
        return result;
    }

    result.ok = true;
    result.path = path;
    result.fileBytes = static_cast<quint64>(info.size());
    result.fileCrc32 = crc;
    if (progress)
        progress(1.0, QStringLiteral("RAW文件校验通过。"));
    return result;
}
