import Foundation
import HotSyncCore

// Reading one PIM database of a Palm OS Cobalt device for the engine: the
// `cobalt...` commands of hotsync-session in order (open, schema, categories,
// rows, close), the schema checked against the layouts the T|X reported, and
// the rows converted to Garnet records (CobaltRecords). Read-only: nothing
// here writes a row, and the database is opened for reading.

/// What the read of one database gave: what the Palm reported and the rows
/// as the engine takes them.
public struct CobaltDatabaseRead: Equatable, Sendable {
    public let kind: PalmPIMFamily.Kind
    public let columns: [CobaltColumn]
    public let categories: CobaltCategoryMap
    public let rows: [CobaltRow]
    /// one per row that made a record, deleted rows included (without data)
    public let records: [PalmRecordIn]
    /// rows that made no record (a calendar row without a start): they stay
    /// on the Palm and the Mac never sees them
    public let skipped: [UInt32]
    /// what the converters dropped or could not read, with the row's id
    public let warnings: [String]

    public init(kind: PalmPIMFamily.Kind, columns: [CobaltColumn], categories: [CobaltCategory], rows: [CobaltRow]) {
        self.kind = kind
        self.columns = columns
        self.categories = CobaltCategoryMap(categories)
        self.rows = rows
        var records: [PalmRecordIn] = []
        var skipped: [UInt32] = []
        var warnings: [String] = []
        for row in rows {
            let converted = CobaltRecords.palmRecord(of: row, kind: kind, schema: columns, categories: self.categories)
            let label = String(format: "row 0x%08X", row.rowId)
            warnings += converted.warnings.map { "\(label): \($0)" }
            if let record = converted.record { records.append(record) } else { skipped.append(row.rowId) }
        }
        self.records = records
        self.skipped = skipped
        self.warnings = warnings
    }

    /// The AppInfo block of the Garnet database of this kind holding the
    /// Palm's categories: what the app's two-way sync reads categories from
    /// (`PalmPIMFamily.categories(ofAppInfo:kind:)`).
    public var appInfo: Data { Self.garnetAppInfo(categories.appInfo, kind: kind) }

    public static func garnetAppInfo(_ categories: CategoryAppInfo, kind: PalmPIMFamily.Kind) -> Data {
        switch kind {
        case .calendar: return CalendarAppInfo(categories: categories).encode()
        case .contacts:
            return ContactAppInfo(categories: categories, labels: Array(repeating: "", count: ContactAppInfo.labelCountV11)).encode()
        case .tasks: return TaskAppInfo(categories: categories).encode()
        case .memos: return MemoAppInfo(categories: categories).encode()
        }
    }
}

extension CobaltRecords {
    /// The engine's record of a row: the Garnet record of the kind, the
    /// index of the row's first category in the Garnet block, and the Garnet
    /// attributes. A deleted row has no data, like a deleted record of
    /// `readall`. nil: the row makes no record (see `CobaltDatabaseRead.skipped`).
    public static func palmRecord(of row: CobaltRow, kind: PalmPIMFamily.Kind, schema: [CobaltColumn],
                                  categories: CobaltCategoryMap) -> CobaltConverted<PalmRecordIn?> {
        let attributes = recordAttributes(of: row)
        let category = categories.index(of: row)
        if row.deleted {
            return CobaltConverted(record: PalmRecordIn(id: row.rowId, attributes: attributes, category: category, data: Data()), warnings: [])
        }
        let data: Data?
        let warnings: [String]
        switch kind {
        case .memos:
            let c = memo(row, schema: schema)
            (data, warnings) = (c.record.encode(), c.warnings)
        case .calendar:
            let c = calendarEvent(row, schema: schema)
            (data, warnings) = (c?.record.encode(), c?.warnings ?? ["no start: not an event"])
        case .tasks:
            let c = task(row, schema: schema)
            (data, warnings) = (c.record.encode(), c.warnings)
        case .contacts:
            let c = contact(row, schema: schema)
            (data, warnings) = (c.record.encode(), c.warnings)
        }
        guard let data else { return CobaltConverted(record: nil, warnings: warnings) }
        return CobaltConverted(record: PalmRecordIn(id: row.rowId, attributes: attributes, category: category, data: data), warnings: warnings)
    }
}

/// The read of one Cobalt PIM database as a conversation with
/// hotsync-session: `openCommand` goes first, then every event of the
/// session is handed to `handle`, which says what to send next, to wait, or
/// that the read is over. The database is opened for reading (mode 1) and
/// closed with flags 0 (a read-only open refuses the sync-token flag).
///
/// The schema the Palm reports is verified before a row is read; one that
/// differs from the T|X's layout (`CobaltSchema`) ends the read with
/// `mismatches` and no result, since the converters would misread the rows.
/// An error event of any of the read's commands ends it too; a database
/// that was opened is closed first.
public struct CobaltDatabaseReader: Equatable, Sendable {
    public enum Step: Equatable, Sendable { case opening, schema, categories, rows, closing, done }

    public enum Action: Equatable, Sendable {
        /// a command for hotsync-session
        case send(String)
        /// the event was not the answer yet (or none of this read's)
        case wait
        /// the read is over: `result` has the rows, or `failure` says why not
        case finished
    }

    public let kind: PalmPIMFamily.Kind
    public private(set) var step: Step = .opening
    public private(set) var handle: Int?
    public private(set) var columns: [CobaltColumn] = []
    public private(set) var categories: [CobaltCategory] = []
    public private(set) var rows: [CobaltRow] = []
    public private(set) var mismatches: [CobaltSchemaMismatch] = []
    public private(set) var failure: String?
    public private(set) var result: CobaltDatabaseRead?

    public init(kind: PalmPIMFamily.Kind) {
        self.kind = kind
    }

    /// The stages an `error` event of this read names.
    public static let stages: Set<String> = ["cobaltopen", "cobaltschema", "cobaltcategories", "cobaltreadall", "cobaltclose"]

    public var database: String { PalmPIMFamily.cobalt.databaseName(kind) }
    public var creator: String { PalmPIMFamily.cobalt.creator(kind) }
    public var table: String { CobaltSchema.table(for: kind) }

    /// The first command: open the database for reading.
    public var openCommand: String { "cobaltopen \(database) \(creator) 1" }

    public var isDone: Bool { step == .done }

    public mutating func handle(_ event: SessionEvent) -> Action {
        switch event {
        case .cobalt(let cobalt):
            return handle(cobalt)
        case .error(let stage, let message) where Self.stages.contains(stage):
            return fail("\(stage): \(message)")
        default:
            return .wait
        }
    }

    public mutating func handle(_ event: CobaltEvent) -> Action {
        switch (step, event) {
        case (.opening, .opened(let h, _, _, _)):
            handle = h
            step = .schema
            return .send("cobaltschema \(h) \(table)")
        case (.schema, .column(let h, let t, let column)) where h == handle && t == table:
            columns.append(column)
            return .wait
        case (.schema, .schemaDone(let h, _, _)) where h == handle:
            mismatches = CobaltSchemaCheck.verify(columns, kind: kind)
            guard mismatches.isEmpty else {
                return fail("\(database): the \(table) table differs from the known layout (\(mismatches.count) differences)")
            }
            step = .categories
            return .send("cobaltcategories \(h)")
        case (.categories, .category(let h, let category)) where h == handle:
            categories.append(category)
            return .wait
        case (.categories, .categoriesDone(let h, _)) where h == handle:
            step = .rows
            return .send("cobaltreadall \(h) \(table)")
        case (.rows, .row(let h, _, let row)) where h == handle:
            rows.append(row)
            return .wait
        case (.rows, .rowsDone(let h, _, _, _)) where h == handle:
            result = CobaltDatabaseRead(kind: kind, columns: columns, categories: categories, rows: rows)
            return close()
        case (.closing, .closed(let h, _, _)) where h == handle:
            step = .done
            return .finished
        default:
            return .wait
        }
    }

    private mutating func close() -> Action {
        guard let handle, step != .closing, step != .done else {
            step = .done
            return .finished
        }
        step = .closing
        return .send("cobaltclose \(handle) 0")
    }

    private mutating func fail(_ reason: String) -> Action {
        if failure == nil { failure = reason }
        return close()
    }
}
