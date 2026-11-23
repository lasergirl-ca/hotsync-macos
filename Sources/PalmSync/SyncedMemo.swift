import Foundation

/// The part of a memo both sides can hold: its text (the first line is
/// the title on both) and the category, which is the Notes folder.
public struct SyncedMemo: Equatable, Hashable, Codable, Sendable {
    public var text: String
    public var category: String

    public enum Field: String, CaseIterable, Codable, Sendable {
        case text, category
    }

    public init(text: String, category: String) {
        self.text = text
        self.category = category
    }

    public init(_ record: PalmMemo, category: String) {
        text = record.text
        self.category = category
    }
}

extension SyncedMemo: SyncedItem {
    public typealias PalmRecord = PalmMemo

    /// The first line, cut short for the log.
    public var title: String? {
        let first = String(text.prefix { $0 != "\n" })
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }

    public static func palmRecord(from data: Data) throws -> PalmMemo { try PalmMemo(data: data) }
    public static func encode(_ record: PalmMemo) -> Data { record.encode() }
    public func newPalmRecord() -> PalmMemo { PalmMemo(text: text) }

    public func apply(to record: inout PalmMemo) {
        record.text = text
    }

    public mutating func set(_ field: Field, from other: SyncedMemo) {
        switch field {
        case .text: text = other.text
        case .category: category = other.category
        }
    }

    public func differs(from other: SyncedMemo, in field: Field) -> Bool {
        switch field {
        case .text: return text != other.text
        case .category: return category != other.category
        }
    }

    public func describe(_ field: Field) -> String {
        switch field {
        case .text: return text.count > 80 ? String(text.prefix(77)) + "…" : text
        case .category: return category
        }
    }

    /// A memo has no dates.
    public func shiftingDates(by years: Int) -> SyncedMemo { self }

    /// Slow sync: the same first line.
    public func matches(_ other: SyncedMemo) -> Bool {
        title == other.title
    }
}

public typealias MemoSyncPlan = SyncPlan<SyncedMemo>
public typealias MemoMirror = SyncMirror<SyncedMemo>

extension SyncPlan where Item == SyncedMemo {
    /// The Palm's side of the plan as a whole memo database to install, by
    /// title. The Palm's own AppInfo bytes are kept; only the categories
    /// change. Name and creator are the Garnet ones; `PalmPIMFamily
    /// .deviceDatabase` turns it into a MemoDB for a classic Palm.
    public func palmDatabase(appInfo existing: MemoAppInfo)
        -> (database: PalmDatabase, palmIDs: [Int: UInt32], categories: CategoryAppInfo) {
        let (records, palmIDs, categories, nextID) = palmRecords(categories: existing.categories) { a, b in
            a.text.localizedCaseInsensitiveCompare(b.text) == .orderedAscending
        }
        var appInfo = existing
        appInfo.categories = categories
        var db = PalmDatabase(name: MemosBuilder.databaseName, type: "DATA", creator: MemosBuilder.creator, attributes: 0, version: 0,
                              appInfo: appInfo.encode())
        db.records = records
        db.uniqueIDSeed = nextID
        return (db, palmIDs, categories)
    }
}
