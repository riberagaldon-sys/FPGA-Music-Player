#include "LrcParser.h"

#include <QFile>
#include <QFont>
#include <QHash>
#include <QImage>
#include <QPainter>
#include <QRegularExpression>
#include <QSet>

#include <algorithm>

namespace {

QString decodeLrcText(QByteArray bytes)
{
    if (bytes.startsWith(QByteArray("\xEF\xBB\xBF", 3)))
        bytes.remove(0, 3);
    if (bytes.startsWith(QByteArray("\xFF\xFE", 2))
        || bytes.startsWith(QByteArray("\xFE\xFF", 2))) {
        const bool littleEndian = quint8(bytes.at(0)) == 0xff;
        QString text;
        text.reserve((bytes.size() - 2) / 2);
        for (qsizetype index = 2; index + 1 < bytes.size(); index += 2) {
            const quint8 first = quint8(bytes.at(index));
            const quint8 second = quint8(bytes.at(index + 1));
            const ushort value = littleEndian
                ? ushort(first | (ushort(second) << 8))
                : ushort((ushort(first) << 8) | second);
            text.append(QChar(value));
        }
        return text;
    }

    QString text = QString::fromUtf8(bytes);
    if (text.contains(QChar(0xfffd))) {
        // A considerable number of Chinese LRC files are still saved in the
        // Windows ANSI/GBK code page.  On a Chinese Windows installation,
        // fromLocal8Bit() recovers those files without adding Qt5Compat.
        const QString local = QString::fromLocal8Bit(bytes);
        if (!local.contains(QChar(0xfffd)))
            text = local;
    }
    return text;
}

quint32 fractionToMs(const QString &fraction)
{
    if (fraction.isEmpty())
        return 0;
    if (fraction.size() == 1)
        return fraction.toUInt() * 100;
    if (fraction.size() == 2)
        return fraction.toUInt() * 10;
    return fraction.left(3).toUInt();
}

QByteArray fixed16(QByteArray value)
{
    if (value.size() > BoardLyricPage::LcdColumns)
        value.truncate(BoardLyricPage::LcdColumns);
    value.append(QByteArray(BoardLyricPage::LcdColumns - value.size(), ' '));
    return value;
}

bool isCustomCell(QChar ch)
{
    const ushort value = ch.unicode();
    return value < 0x20 || value > 0x7e;
}

// Render one Unicode character into the 5x8 dot matrix used by CGRAM.  The
// source image is deliberately larger than the target so Qt's font fallback
// can draw CJK glyphs before the bitmap is reduced to the LCD resolution.
QByteArray glyphBitmap(QChar character)
{
    QImage source(32, 32, QImage::Format_ARGB32);
    source.fill(Qt::black);
    QPainter painter(&source);
    QFont font(QStringLiteral("Microsoft YaHei UI"));
    font.setPixelSize(27);
    font.setStyleStrategy(QFont::NoAntialias);
    painter.setFont(font);
    painter.setPen(Qt::white);
    painter.drawText(source.rect(), Qt::AlignCenter, QString(character));
    painter.end();

    const QImage reduced = source.scaled(5, BoardLyricPage::GlyphRows,
                                         Qt::IgnoreAspectRatio,
                                         Qt::FastTransformation);
    QByteArray bitmap(BoardLyricPage::GlyphRows, char(0));
    for (int row = 0; row < BoardLyricPage::GlyphRows; ++row) {
        quint8 bits = 0;
        for (int column = 0; column < 5; ++column) {
            if (qGray(reduced.pixel(column, row)) >= 80)
                bits |= quint8(1U << (4 - column));
        }
        bitmap[row] = char(bits & 0x1f);
    }

    // If a platform font has no glyph at all, keep a visible placeholder
    // instead of silently displaying a blank cell on the board.
    bool empty = true;
    for (char value : bitmap) {
        if (value != 0) {
            empty = false;
            break;
        }
    }
    if (empty) {
        bitmap[0] = char(0x1f);
        bitmap[1] = char(0x11);
        bitmap[2] = char(0x15);
        bitmap[3] = char(0x11);
        bitmap[4] = char(0x15);
        bitmap[5] = char(0x11);
        bitmap[6] = char(0x1f);
    }
    return bitmap;
}

QByteArray encodeRow(const QString &text,
                     QHash<QChar, int> &glyphSlots,
                     QByteArray &glyphs)
{
    QByteArray encoded;
    encoded.reserve(BoardLyricPage::LcdColumns);
    const int limit = qMin(BoardLyricPage::LcdColumns, text.size());
    for (int index = 0; index < limit; ++index) {
        QChar character = text.at(index);
        if (character == QLatin1Char('\t') || character.unicode() < 0x20)
            character = QLatin1Char(' ');

        if (!isCustomCell(character)) {
            encoded.append(char(character.unicode()));
            continue;
        }

        int slot = glyphSlots.value(character, -1);
        if (slot < 0) {
            slot = glyphSlots.size();
            // splitText() guarantees this branch never exceeds eight slots;
            // keep a defensive fallback for a future caller.
            if (slot >= BoardLyricPage::GlyphSlots) {
                encoded.append('?');
                continue;
            }
            glyphSlots.insert(character, slot);
            const QByteArray bitmap = glyphBitmap(character);
            for (int row = 0; row < BoardLyricPage::GlyphRows; ++row)
                glyphs[slot * BoardLyricPage::GlyphRows + row] = bitmap.at(row);
        }
        encoded.append(char(slot));
    }
    return fixed16(encoded);
}

BoardLyricPage makePage(quint32 timeMs, const QString &line1Text,
                        const QString &line2Text)
{
    BoardLyricPage page;
    page.timeMs = timeMs;
    page.previewLine1 = line1Text.left(BoardLyricPage::LcdColumns);
    page.previewLine2 = line2Text.left(BoardLyricPage::LcdColumns);
    page.glyphs = QByteArray(BoardLyricPage::GlyphBytes, char(0));
    QHash<QChar, int> glyphSlots;
    page.line1 = encodeRow(page.previewLine1, glyphSlots, page.glyphs);
    page.line2 = encodeRow(page.previewLine2, glyphSlots, page.glyphs);
    return page;
}

QVector<QString> splitText(const QString &text)
{
    QVector<QString> chunks;
    QString chunk;
    QSet<QChar> customCharacters;
    // The two rows on one LCD page share the same eight CGRAM slots.  Keep a
    // page-level character set in addition to the row length so a pair of
    // rows can never require more than eight custom glyphs.  Empty padding
    // chunks preserve the two-row page alignment when a page ends early.
    int rowsUsed = 0;

    const auto flushRow = [&] {
        if (!chunk.isEmpty()) {
            chunks.push_back(chunk);
            ++rowsUsed;
        }
        chunk.clear();
    };

    const auto startNextPage = [&] {
        if (rowsUsed == 1)
            chunks.push_back(QString());
        rowsUsed = 0;
        customCharacters.clear();
    };

    for (int index = 0; index < text.size(); ++index) {
        QChar character = text.at(index);
        // LCD cells are single 8-bit values.  Replace UTF-16 surrogate pairs
        // with a visible placeholder rather than splitting a pair in half.
        if (character.isHighSurrogate()) {
            if (index + 1 < text.size() && text.at(index + 1).isLowSurrogate())
                ++index;
            character = QLatin1Char('?');
        } else if (character.isLowSurrogate()) {
            character = QLatin1Char('?');
        }
        if (character == QLatin1Char('\t') || character.unicode() < 0x20)
            character = QLatin1Char(' ');
        if (character.isSpace())
            character = QLatin1Char(' ');

        const bool custom = isCustomCell(character);
        // Each chunk becomes one LCD row.  Keeping it to 16 cells here is
        // important: makePage() places two chunks on a page and must never
        // truncate the second half of a long Chinese line.
        if (chunk.size() >= BoardLyricPage::LcdColumns) {
            flushRow();
            if (rowsUsed == 2) {
                rowsUsed = 0;
                customCharacters.clear();
            }
        }
        if (custom && !customCharacters.contains(character)
            && customCharacters.size() >= BoardLyricPage::GlyphSlots) {
            // There is no CGRAM slot left on this page.  Finish the current
            // row (if any), pad an incomplete first row, then continue on a
            // fresh page.
            flushRow();
            startNextPage();
        }
        chunk.append(character);
        if (custom)
            customCharacters.insert(character);
    }
    flushRow();
    if (rowsUsed == 1)
        chunks.push_back(QString());
    if (chunks.isEmpty()) {
        chunks.push_back(QStringLiteral(" "));
        chunks.push_back(QString());
    }
    return chunks;
}

} // namespace

LrcParseResult LrcParser::parseFile(const QString &path,
                                    const QString &boardTitle)
{
    LrcParseResult result;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        result.error = QStringLiteral("无法打开LRC文件：%1").arg(file.errorString());
        return result;
    }

    QString source = decodeLrcText(file.readAll());
    if (!source.isEmpty() && source.front() == QChar(0xfeff))
        source.remove(0, 1);

    const QRegularExpression timeTag(
        QStringLiteral(R"(\[(\d{1,3}):(\d{1,2})(?:[\.:](\d{1,3}))?\])"));
    const QStringList lines = source.split(
        QRegularExpression(QStringLiteral("[\r\n]+")), Qt::SkipEmptyParts);

    for (const QString &rawLine : lines) {
        auto iterator = timeTag.globalMatch(rawLine);
        QVector<qint64> times;
        int lyricStart = -1;
        while (iterator.hasNext()) {
            const QRegularExpressionMatch match = iterator.next();
            const qint64 milliseconds =
                match.captured(1).toLongLong() * 60'000
                + match.captured(2).toLongLong() * 1'000
                + fractionToMs(match.captured(3));
            times.push_back(milliseconds);
            lyricStart = match.capturedEnd();
        }
        if (times.isEmpty() || lyricStart < 0)
            continue;

        const QString text = normalizePunctuation(
            rawLine.mid(lyricStart).trimmed());
        if (text.isEmpty() || isMetadata(text))
            continue;
        for (qint64 time : times)
            result.entries.push_back({time, text});
    }

    std::stable_sort(result.entries.begin(), result.entries.end(),
                     [](const LrcEntry &a, const LrcEntry &b) {
                         return a.timeMs < b.timeMs;
                     });
    if (result.entries.isEmpty()) {
        result.error = QStringLiteral("LRC中没有找到有效的时间戳歌词。");
        return result;
    }

    // Merge duplicate timestamps before pagination.  This keeps a bilingual
    // line together and makes Chinese/English LRC files behave identically.
    QVector<LrcEntry> merged;
    for (const LrcEntry &entry : result.entries) {
        if (!merged.isEmpty() && merged.back().timeMs == entry.timeMs)
            merged.back().text += QStringLiteral(" ") + entry.text;
        else
            merged.push_back(entry);
    }

    const QVector<QString> titleChunks = splitText(
        normalizePunctuation(boardTitle.isEmpty()
                                 ? QStringLiteral("GX Music Studio")
                                 : boardTitle));
    const QString titleLine = titleChunks.isEmpty()
        ? QStringLiteral("GX Music Studio")
        : titleChunks.first().left(BoardLyricPage::LcdColumns);
    result.boardPages.push_back(makePage(
        0, titleLine, QStringLiteral("PC IMPORT READY")));

    const qint64 allLyricsEnd = merged.back().timeMs;
    for (qsizetype entryIndex = 0; entryIndex < merged.size(); ++entryIndex) {
        const LrcEntry &entry = merged.at(entryIndex);
        qint64 nextMs = entryIndex + 1 < merged.size()
            ? merged.at(entryIndex + 1).timeMs
            : std::max(allLyricsEnd, entry.timeMs + 5'000);
        if (nextMs <= entry.timeMs)
            nextMs = entry.timeMs + 1;

        const QVector<QString> chunks = splitText(entry.text);
        const int pageCount = qMax(1, (chunks.size() + 1) / 2);
        for (int page = 0; page < pageCount; ++page) {
            qint64 pageMs = entry.timeMs
                + ((nextMs - entry.timeMs) * page) / pageCount;
            if (!result.boardPages.isEmpty()
                && pageMs <= result.boardPages.back().timeMs) {
                pageMs = result.boardPages.back().timeMs + 1;
            }
            const QString line1 = chunks.value(page * 2);
            const QString line2 = chunks.value(page * 2 + 1);
            result.boardPages.push_back(makePage(
                static_cast<quint32>(pageMs), line1, line2));
        }
    }

    qint64 blankMs = std::max(
        allLyricsEnd,
        static_cast<qint64>(result.boardPages.back().timeMs) + 1);
    result.boardPages.push_back(makePage(static_cast<quint32>(blankMs),
                                         QString(), QString()));

    if (result.boardPages.size() > 256) {
        result.error = QStringLiteral(
            "转换后有%1个LCD页面，超过板端上限256页。请精简LRC。")
                           .arg(result.boardPages.size());
        result.boardPages.clear();
        return result;
    }

    result.ok = true;
    return result;
}

QString LrcParser::normalizePunctuation(QString text)
{
    return text.replace(QChar(0x2018), QLatin1Char('\''))
        .replace(QChar(0x2019), QLatin1Char('\''))
        .replace(QChar(0x201c), QLatin1Char('"'))
        .replace(QChar(0x201d), QLatin1Char('"'))
        .replace(QChar(0x2013), QLatin1Char('-'))
        .replace(QChar(0x2014), QLatin1Char('-'))
        .simplified();
}

bool LrcParser::isMetadata(const QString &text)
{
    const QString lower = text.toLower();
    static const QStringList prefixes = {
        QStringLiteral("lyrics by"), QStringLiteral("composed by"),
        QStringLiteral("produced by"), QStringLiteral("written by"),
        QStringLiteral("作词"), QStringLiteral("作曲"), QStringLiteral("编曲")
    };
    return std::any_of(prefixes.cbegin(), prefixes.cend(),
                       [&lower](const QString &prefix) {
                           return lower.startsWith(prefix);
                       });
}
