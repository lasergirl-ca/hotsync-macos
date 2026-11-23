import Foundation

/// A note as the Mac has it, without Notes.app: its text as plain text,
/// the first line being what Notes shows as the title.
public struct MacNote: Equatable, Sendable {
    public var id: String
    public var folderID: String
    public var text: String

    public init(id: String, folderID: String, text: String) {
        self.id = id
        self.folderID = folderID
        self.text = text
    }
}

/// Builds a complete MemosDB-PMem from the Mac's notes: the one-way sync
/// where the database is installed whole.
///
/// - Each Notes folder is a Palm category; past 15 they fold into "Other".
/// - A note's text goes on as the memo, see `PalmMemo.limited`: plain
///   text only, cut to what the Palm's application holds (4 KB for Memo
///   Pad, 32 KB for Memos). Formatting, attachments, images, checklists
///   and tables do not travel; a note the Palm edits comes back as plain
///   text.
public struct MemosBuilder {
    public struct MacFolder: Equatable, Sendable {
        public var id: String
        public var title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Options: Sendable {
        public var folders: [MacFolder]
        /// Bytes of text one memo holds on this Palm.
        public var maxBytes: Int

        public init(folders: [MacFolder], maxBytes: Int = PalmPIMFamily.garnet.memoTextLimit) {
            self.folders = folders
            self.maxBytes = maxBytes
        }
    }

    public struct Report: Equatable, Sendable {
        public var records = 0
        /// Notes longer than a memo holds, cut short on the Palm.
        public var truncated = 0
        /// Notes with nothing in them once limited, left out.
        public var emptySkipped = 0
        public var categories: [String] = []
        public var warnings: [String] = []
    }

    public static let databaseName = "MemosDB-PMem"
    public static let creator = "PMem"
    public static let maxCategories = 16
    public static let overflowCategory = "Other"

    public let options: Options

    public init(options: Options) {
        self.options = options
    }

    public func build(_ notes: [MacNote]) -> (database: PalmDatabase, report: Report) {
        var report = Report()

        var names = ["Unfiled"]
        var categoryOf: [String: Int] = [:]
        var overflow = false
        for folder in options.folders {
            let name = String(folder.title.prefix(CategoryAppInfo.nameWidth - 1))
            if let i = names.firstIndex(of: name) {
                categoryOf[folder.id] = i
            } else if names.count < Self.maxCategories - 1 {
                names.append(name)
                categoryOf[folder.id] = names.count - 1
            } else {
                if !overflow {
                    names.append(Self.overflowCategory)
                    overflow = true
                    report.warnings.append("more than \(Self.maxCategories - 2) folders: the rest go into \"\(Self.overflowCategory)\"")
                }
                categoryOf[folder.id] = names.firstIndex(of: Self.overflowCategory)!
            }
        }

        var memos: [(PalmMemo, Int)] = []
        for note in notes {
            guard let memo = convert(note, &report) else { continue }
            memos.append((memo, categoryOf[note.folderID] ?? 0))
        }
        memos.sort { $0.0.text.localizedCaseInsensitiveCompare($1.0.text) == .orderedAscending }

        var db = PalmDatabase(name: Self.databaseName, type: "DATA", creator: Self.creator, attributes: 0, version: 0,
                              appInfo: MemoAppInfo(categories: CategoryAppInfo(names: names)).encode())
        db.records = memos.enumerated().map { i, m in
            PalmDatabase.Record(category: m.1, uniqueID: UInt32(i + 1), data: m.0.encode())
        }
        db.uniqueIDSeed = UInt32(memos.count + 1)
        report.records = memos.count
        report.categories = names
        if report.truncated > 0 {
            report.warnings.append("\(report.truncated) notes longer than \(options.maxBytes / 1024) KB are cut short on the Palm")
        }
        return (db, report)
    }

    /// The memo for a note; nil for one with no text left once limited.
    func convert(_ note: MacNote, _ report: inout Report) -> PalmMemo? {
        let text = PalmMemo.limited(note.text, maxBytes: options.maxBytes)
        guard !text.isEmpty else {
            report.emptySkipped += 1
            return nil
        }
        if PalmText.bytes(PalmMemo.limited(note.text, maxBytes: Int.max)).count > options.maxBytes { report.truncated += 1 }
        return PalmMemo(text: text)
    }

    /// One note as a Palm record, nothing reported; nil for an empty one.
    public func palmMemo(_ note: MacNote) -> PalmMemo? {
        var report = Report()
        return convert(note, &report)
    }

    /// The Mac's notes as the sync engine takes them: each folder a
    /// category, each note keyed by its Notes identifier, its text already
    /// limited to what the Palm holds, so what comes back compares equal.
    /// Notes with no text are left out: the Palm has nothing to show for
    /// them.
    public func syncItems(_ notes: [MacNote]) -> [MacSyncItem<SyncedMemo>] {
        var report = Report()
        let categoryOf = Dictionary(options.folders.map { ($0.id, String($0.title.prefix(CategoryAppInfo.nameWidth - 1))) },
                                    uniquingKeysWith: { a, _ in a })
        return notes.compactMap { note in
            guard let memo = convert(note, &report) else { return nil }
            return MacSyncItem(key: MacKey(seriesID: note.id), item: SyncedMemo(memo, category: categoryOf[note.folderID] ?? "Unfiled"),
                               palmRecord: memo.encode())
        }
    }
}
