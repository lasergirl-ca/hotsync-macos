import Foundation

/// A record of the Memos application (Palm OS 5.2 and later: database
/// MemosDB-PMem, creator PMem) and of the Memo Pad before it (MemoDB,
/// creator memo). Both write the same record, as pilot-link's memo.c reads
/// and writes it: the text, NUL-terminated, Windows-1252, lines ending in
/// LF. Nothing else is in the record; the category sits in the record's
/// header, the private flag in its attributes.
///
/// Memo Pad holds up to 4 KB of text per memo, Memos up to 32 KB
/// (`PalmPIMFamily.memoTextLimit`); what goes onto the Palm is cut to
/// that, see `limited(_:maxBytes:)`.
public struct PalmMemo: Equatable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        text = try r.cString()
        guard r.isAtEnd else { throw PalmFormatError.trailingBytes(count: r.remaining) }
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.cString(text)
        return w.data
    }

    /// The first line, which both Memo Pad and Memos show as the memo's
    /// title; what the log calls the memo.
    public var title: String {
        String(text.prefix { $0 != "\n" })
    }

    /// The memo's bytes on the Palm, without the NUL.
    public var byteCount: Int { PalmText.bytes(text).count }

    // MARK: What a memo holds

    /// Text as a memo holds it and as it comes back from the Mac's Notes:
    /// lines end in LF, no space at a line's start or end, runs of spaces
    /// and tabs are one space (Notes collapses them as HTML does), no
    /// blank line first or last, every character one Windows-1252 has (the
    /// others become "?"), and at most `maxBytes` of it, cut on a line
    /// break when one is near, else on a character. Applying it twice
    /// changes nothing, so a round trip Mac → Palm → Mac compares equal.
    public static func limited(_ text: String, maxBytes: Int) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        // through the Palm's charset and back: what it cannot hold is "?"
        let joined = PalmText.string(PalmText.bytes(lines.joined(separator: "\n"))[...])
        let bytes = PalmText.bytes(joined)
        guard bytes.count > maxBytes else { return joined }
        var cut = maxBytes
        if let lineBreak = bytes[..<maxBytes].lastIndex(of: 0x0A), lineBreak > maxBytes - 200 { cut = lineBreak }
        // the cut can leave a space or a blank line at the end: once more
        return limited(PalmText.string(bytes[..<cut]), maxBytes: maxBytes)
    }

    /// Text cut to `maxBytes`, nothing else changed: what a Palm record
    /// gets when it goes to a Palm whose application holds less (a Garnet
    /// memo onto a Memo Pad). The Palm's own text is left as it is.
    public static func truncated(_ text: String, maxBytes: Int) -> String {
        let bytes = PalmText.bytes(text)
        guard bytes.count > maxBytes else { return text }
        return PalmText.string(bytes[..<maxBytes])
    }
}

/// The AppInfo block of MemoDB and MemosDB-PMem: the category block and
/// what the application keeps after it (pilot-link: two bytes of padding,
/// the sort order, one more byte, 282 bytes in all; an m515 writes the
/// same, a T|X 300 bytes), kept as read.
public struct MemoAppInfo: Equatable, Sendable {
    public var categories: CategoryAppInfo
    public var internalBytes: Data

    /// What the applications write after the categories: Memo Pad on an
    /// m515 (Palm OS 4.1) four bytes, Memos on a T|X (Palm OS 5.4.9) 22.
    public static let classicInternalSize = 4
    public static let garnetInternalSize = 22

    public init(categories: CategoryAppInfo = CategoryAppInfo(), internalSize: Int = Self.garnetInternalSize) {
        self.categories = categories
        internalBytes = Data(count: internalSize)
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        categories = try CategoryAppInfo(bytes: try r.slice(CategoryAppInfo.size))
        internalBytes = Data(r.rest())
    }

    /// Sort alphabetically (true) or by hand (false), the byte pilot-link
    /// calls sortByAlpha.
    public var sortByAlpha: Bool {
        internalBytes.count > 2 && internalBytes[internalBytes.startIndex + 2] != 0
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.append(categories.encode())
        w.append(internalBytes)
        return w.data
    }
}
