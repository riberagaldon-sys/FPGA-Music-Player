#pragma once

#include <QByteArray>
#include <QString>
#include <QVector>

struct LrcEntry
{
    qint64 timeMs = 0;
    QString text;
};

struct BoardLyricPage
{
    // A standard HD44780 LCD1602 has eight writable 5x8 CGRAM glyphs.  The
    // GXM record carries the two 16-cell rows plus those glyphs for this page.
    // Non-ASCII cells in line1/line2 are encoded as bytes 0..7 (CGRAM slot).
    static constexpr int LcdColumns = 16;
    static constexpr int GlyphSlots = 8;
    static constexpr int GlyphRows = 8;
    static constexpr int GlyphBytes = GlyphSlots * GlyphRows;
    static constexpr int RecordBytes = 4 + LcdColumns + LcdColumns + GlyphBytes;

    quint32 timeMs = 0;
    QByteArray line1;
    QByteArray line2;
    QByteArray glyphs;
    // The encoded rows above are for the FPGA.  Keep the original Unicode
    // rows as well so Qt previews and the board page never fall back to
    // QString::fromLatin1() for Chinese lyrics.
    QString previewLine1;
    QString previewLine2;
};

struct LrcParseResult
{
    bool ok = false;
    QString error;
    QString warning;
    QVector<LrcEntry> entries;
    QVector<BoardLyricPage> boardPages;
};

class LrcParser
{
public:
    static LrcParseResult parseFile(const QString &path,
                                    const QString &boardTitle);

private:
    static QString normalizePunctuation(QString text);
    static bool isMetadata(const QString &text);
};
