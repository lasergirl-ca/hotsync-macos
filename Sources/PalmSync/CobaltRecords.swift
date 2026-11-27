import Foundation
import HotSyncCore

// Palm OS Cobalt 6.1 keeps its PIM data in schema databases (AddressDBS,
// DateBookDBS, ToDoDBS, MemoDBS): tables of typed columns, rows with a
// 32-bit id and a set of categories. hotsync-session reads them with the
// Cobalt DLP commands and hands each row over as `CobaltRow` with the raw
// column bytes. This file converts those rows at the edge into the Garnet
// records the sync engine works on (CalendarEvent, Contact, PalmTask,
// PalmMemo), the way ClassicRecords.swift does for Palm OS before 5.2.
//
// Three things about the bytes are not yet confirmed on a device with rows
// (Planning/cobalt-pim.md, open questions 4 and 5) and sit behind one
// function or constant each so that a real row can flip them:
// `cobaltDate(_:)` (the 2-byte Date), `cobaltDateTimeInterpretation` with
// `cobaltDateTime(_:)` (the 32-bit DateTimeSecs) and `cobaltString(_:)`
// (the VarChar encoding).

// MARK: - Column types

/// Column types of SchemaDatabases.h.
public enum CobaltColumnType: UInt8, Sendable {
    case uint8 = 1, uint16 = 2, uint32 = 3, uint64 = 4
    case int8 = 5, int16 = 6, int32 = 7, int64 = 8
    case float = 9, double = 0xA
    case boolean = 0xB
    case dateTime = 0xC, date = 0xD, time = 0xE
    case char = 0xF, varChar = 0x10, blob = 0x11
    case dateTimeSecs = 0x12

    /// 0x80 set on a column type: a vector of the element type.
    public static let vectorFlag: UInt8 = 0x80

    /// The element type of a column type byte (vector flag stripped); nil
    /// for a type this code does not know.
    public static func element(of type: UInt8) -> CobaltColumnType? {
        CobaltColumnType(rawValue: type & ~vectorFlag)
    }

    public static func isVector(_ type: UInt8) -> Bool { type & vectorFlag != 0 }

    /// The size of one value as the T|X stores it (section 10 of the note:
    /// DateTimeSecs 4, Date 2, Boolean 1); nil for variable-size types.
    public var fixedSize: Int? {
        switch self {
        case .uint8, .int8, .boolean, .char: return 1
        case .uint16, .int16, .date, .time: return 2
        case .uint32, .int32, .float, .dateTime, .dateTimeSecs: return 4
        case .uint64, .int64, .double: return 8
        case .varChar, .blob: return nil
        }
    }
}

// MARK: - Decoding primitives (little-endian device bytes)

/// How a 32-bit DateTimeSecs value is read. The Cobalt SDK's file-format
/// documentation (DateBookSchema: "START time & date in posix epoch time,
/// UTC seconds since 1/1/1970") settles it: UTC, with the event's Timezone
/// column naming the zone it is shown in. `.deviceLocalWallClock` stays as
/// the switch to flip should a real row contradict the documentation.
public enum CobaltDateTimeInterpretation: Sendable {
    /// seconds since the epoch in the device's local time: read the
    /// components without a zone shift
    case deviceLocalWallClock
    /// seconds since the epoch in UTC: read the components in the event's
    /// zone (its Timezone column), else the Mac's
    case utc
}

/// Per the SDK documentation (see above); a real row has not confirmed it yet.
public let cobaltDateTimeInterpretation: CobaltDateTimeInterpretation = .utc

/// The DateTimeSecs epoch: 1970-01-01 00:00 UTC ("posix epoch time" in the
/// SDK's DateBookSchema documentation; Palm OS before Cobalt counted from 1904).
public let cobaltDateTimeEpoch = Date(timeIntervalSince1970: 0)

/// RepeatEndDate "never" (section 2.2).
public let cobaltDateTimeNever: UInt32 = 0x7FFF_FFFF

/// Little-endian scalars; nil when the bytes are shorter than the type.
public enum CobaltBytes {
    public static func uint8(_ d: Data) -> UInt8? {
        d.count >= 1 ? d[d.startIndex] : nil
    }

    public static func int8(_ d: Data) -> Int8? {
        uint8(d).map { Int8(bitPattern: $0) }
    }

    public static func uint16(_ d: Data) -> UInt16? {
        guard d.count >= 2 else { return nil }
        let b = Array(d.prefix(2))
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    public static func uint32(_ d: Data) -> UInt32? {
        guard d.count >= 4 else { return nil }
        let b = Array(d.prefix(4))
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    public static func bool(_ d: Data) -> Bool? {
        uint8(d).map { $0 != 0 }
    }

    /// The elements of a vector column: `size / elementSize` values in
    /// order (a trailing partial element is dropped).
    public static func vector(_ d: Data, elementSize: Int) -> [Data] {
        guard elementSize > 0 else { return [] }
        return stride(from: 0, through: d.count - elementSize, by: elementSize).map { offset in
            d.subdata(in: d.startIndex + offset ..< d.startIndex + offset + elementSize)
        }
    }
}

/// The 2-byte Date column (DueDate, Birthday, Anniversary). **Assumption,
/// confirm with a real row:** the classic Palm packed date read
/// little-endian, `(year - 1904) << 9 | month << 5 | day`, as `PalmDate`
/// packs it; 0xFFFF and 0 mean no date.
public func cobaltDate(_ d: Data) -> PalmDate? {
    guard let packed = CobaltBytes.uint16(d), packed != PalmDate.none, packed != 0 else { return nil }
    let date = PalmDate(packed: packed)
    guard (1...12).contains(date.month), (1...31).contains(date.day) else { return nil }
    return date
}

/// The 32-bit DateTimeSecs column as seconds since `cobaltDateTimeEpoch`;
/// nil for a short column or the "never" marker. See
/// `cobaltDateTimeInterpretation` for what the seconds mean.
public func cobaltDateTime(_ d: Data) -> Date? {
    guard let secs = CobaltBytes.uint32(d), secs != cobaltDateTimeNever else { return nil }
    return cobaltDateTimeEpoch.addingTimeInterval(TimeInterval(secs))
}

/// The calendar day and time of day a DateTimeSecs value names, read per
/// `cobaltDateTimeInterpretation`; `zone` is the event's zone when it has one.
public func cobaltDateTimeComponents(_ date: Date, zone: TimeZone?) -> (date: PalmDate, time: PalmTime) {
    var calendar = Calendar(identifier: .gregorian)
    switch cobaltDateTimeInterpretation {
    case .deviceLocalWallClock: calendar.timeZone = TimeZone(identifier: "UTC")!
    case .utc: calendar.timeZone = zone ?? TimeZone.current
    }
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return (PalmDate(year: c.year!, month: c.month!, day: c.day!), PalmTime(hour: c.hour!, minute: c.minute!))
}

/// A VarChar column: the text up to the NUL. **Assumption, confirm with a
/// real row:** UTF-8 (Cobalt is Unicode), with Windows-1252 (Garnet's
/// "Palm Latin") as the fallback when the bytes are not valid UTF-8.
public func cobaltString(_ d: Data) -> String {
    var bytes = d
    if let nul = bytes.firstIndex(of: 0) { bytes = bytes[bytes.startIndex ..< nul] }
    if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
    return PalmText.string(bytes)
}

/// The AddressBookAppInfo Country column (UInt16 'US' packed as two
/// characters: bytes `53 55` on the T|X are 0x5553): the two letters.
public func cobaltCountryCode(_ d: Data) -> String? {
    guard let v = CobaltBytes.uint16(d), v != 0 else { return nil }
    let chars = [UInt8(v >> 8), UInt8(v & 0xFF)]
    guard chars.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
    return String(decoding: chars, as: UTF8.self)
}

// MARK: - Reading a row by column

/// Typed access to a row's columns, collecting warnings (a column too short
/// for its type, a type this code does not read) for the caller to log.
public struct CobaltRowReader {
    public let row: CobaltRow
    public let schema: [UInt32: CobaltColumn]
    public private(set) var warnings: [String] = []
    private var used: Set<UInt32> = []

    /// A converter's own note (a dropped value, an unknown code).
    public mutating func warn(_ text: String) { warnings.append(text) }

    public init(row: CobaltRow, schema: [CobaltColumn]) {
        self.row = row
        self.schema = Dictionary(schema.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, err) in row.columnErrors.sorted(by: { $0.key < $1.key }) {
            warnings.append("row \(row.rowId): column \(id) reported error \(err)")
        }
    }

    private func name(_ id: UInt32) -> String {
        schema[id].map { "\($0.name) (\($0.id))" } ?? "column \(id)"
    }

    /// The bytes of a column; nil when the row does not carry it.
    public mutating func bytes(_ id: UInt32) -> Data? {
        used.insert(id)
        return row.columns[id]
    }

    private mutating func scalar<T>(_ id: UInt32, _ what: String, _ decode: (Data) -> T?) -> T? {
        guard let d = bytes(id) else { return nil }
        if let v = decode(d) { return v }
        if !d.isEmpty { warnings.append("row \(row.rowId): \(name(id)) has \(d.count) bytes, not a \(what)") }
        return nil
    }

    public mutating func uint8(_ id: UInt32) -> UInt8? { scalar(id, "UInt8", CobaltBytes.uint8) }
    public mutating func int8(_ id: UInt32) -> Int8? { scalar(id, "Int8", CobaltBytes.int8) }
    public mutating func uint16(_ id: UInt32) -> UInt16? { scalar(id, "UInt16", CobaltBytes.uint16) }
    public mutating func uint32(_ id: UInt32) -> UInt32? { scalar(id, "UInt32", CobaltBytes.uint32) }
    public mutating func bool(_ id: UInt32) -> Bool? { scalar(id, "Boolean", CobaltBytes.bool) }
    public mutating func date(_ id: UInt32) -> PalmDate? { scalar(id, "Date", cobaltDate) }

    /// nil also for the "never" marker
    public mutating func dateTime(_ id: UInt32) -> Date? {
        guard let d = bytes(id) else { return nil }
        if let v = cobaltDateTime(d) { return v }
        if d.count < 4 { warnings.append("row \(row.rowId): \(name(id)) has \(d.count) bytes, not a DateTimeSecs") }
        return nil
    }

    /// A VarChar; nil when absent or empty (an empty text is no text, as
    /// in the Garnet records).
    public mutating func string(_ id: UInt32) -> String? {
        guard let d = bytes(id) else { return nil }
        let s = cobaltString(d)
        return s.isEmpty ? nil : s
    }

    /// The elements of a vector column, sized by the schema's element type
    /// (or `elementSize` when the schema does not say).
    public mutating func vector(_ id: UInt32, elementSize fallback: Int? = nil) -> [Data] {
        guard let d = bytes(id) else { return [] }
        let size: Int?
        if let column = schema[id], let element = CobaltColumnType.element(of: column.type) {
            size = element.fixedSize ?? fallback
        } else {
            size = fallback
        }
        guard let size else {
            warnings.append("row \(row.rowId): \(name(id)) is a vector of unknown element size, skipped")
            return []
        }
        if d.count % size != 0 { warnings.append("row \(row.rowId): \(name(id)) has \(d.count) bytes, not a multiple of \(size)") }
        return CobaltBytes.vector(d, elementSize: size)
    }

    /// Call last: notes the row's columns the converter did not read, so
    /// a schema with data the Mac drops is visible in the log. Columns the
    /// caller names in `ignoring` (UI state, Yomi names) stay quiet.
    public mutating func finish(ignoring: Set<UInt32> = []) -> [String] {
        for id in row.columns.keys.sorted() where !used.contains(id) && !ignoring.contains(id) {
            let column = schema[id]
            if let column, CobaltColumnType.element(of: column.type) == nil {
                warnings.append("row \(row.rowId): \(name(id)) has unknown type 0x\(String(column.type, radix: 16)), skipped")
            } else if column == nil {
                warnings.append("row \(row.rowId): column \(id) is not in the schema, skipped")
            } else if !(row.columns[id]?.isEmpty ?? true) {
                warnings.append("row \(row.rowId): \(name(id)) is not carried to the Mac")
            }
        }
        return warnings
    }
}

/// A converted row: the Garnet record plus what the conversion had to drop
/// or could not read.
public struct CobaltConverted<Record> {
    public let record: Record
    public let warnings: [String]
}

// MARK: - Categories

/// The categories of a Cobalt database as the engine's single category
/// index: a Garnet-style category block with Unfiled at 0 and the Cobalt
/// categories in the order the device lists them (at most 15 named ones,
/// as the block holds), and the index of a row's first listed category.
public struct CobaltCategoryMap: Equatable, Sendable {
    public let categories: [CobaltCategory]

    public init(_ categories: [CobaltCategory]) {
        self.categories = categories.filter { $0.id != CobaltCategory.unfiledId }
    }

    public static let unfiledName = "Unfiled"

    public func name(of id: UInt32) -> String? {
        id == CobaltCategory.unfiledId ? Self.unfiledName : categories.first { $0.id == id }?.name
    }

    /// The Garnet block: index 0 Unfiled, then the categories; the ids keep
    /// the Palm's numbering so the block says where each came from.
    public var appInfo: CategoryAppInfo {
        let listed = Array(categories.prefix(CategoryAppInfo.count - 1))
        let names = [Self.unfiledName] + listed.map { String($0.name.prefix(CategoryAppInfo.nameWidth - 1)) }
        var ids = [UInt8](repeating: 0, count: CategoryAppInfo.count)
        for (i, c) in listed.enumerated() { ids[i + 1] = UInt8(clamping: c.id) }
        for i in (listed.count + 1)..<CategoryAppInfo.count { ids[i] = UInt8(i) }
        return CategoryAppInfo(names: names, ids: ids)
    }

    /// The engine's category of a row: the first of its categories the
    /// device listed, as an index into `appInfo`; 0 (Unfiled) for none or
    /// for ids the device did not list.
    public func index(of row: CobaltRow) -> Int {
        for id in row.categories where id != CobaltCategory.unfiledId {
            if let i = categories.prefix(CategoryAppInfo.count - 1).firstIndex(where: { $0.id == id }) { return i + 1 }
        }
        return 0
    }

    /// The row's category id for a Garnet index of `appInfo`.
    public func cobaltId(ofIndex index: Int) -> UInt32 {
        index >= 1 && index <= categories.count ? categories[index - 1].id : CobaltCategory.unfiledId
    }
}

// MARK: - The four schemas (as the T|X reports them, section 2.2 / 10)

/// The column lists of the four PIM schema databases as Zoë's T|X running
/// Cobalt 6.1 reports them (ids, names, types, sizes, attributes). The
/// converters key on the ids; `CobaltSchemaCheck` refuses a database whose
/// columns differ.
public enum CobaltSchema {
    public static let memoTable = "MemoDBSchema"
    public static let dateBookTable = "DateBookDBSchema"
    public static let toDoTable = "ToDoDBSchema"
    public static let addressTable = "AddressBookDBSchema"
    public static let addressAppInfoTable = "AddressBookAppInfo"

    public static let memo: [CobaltColumn] = [
        CobaltColumn(id: 100, name: "MemoText", type: 0x10, maxSize: 0xFFFE),
    ]

    public static let dateBook: [CobaltColumn] = [
        CobaltColumn(id: 10, name: "RepeatingEvent", type: 0x0B, maxSize: 1),
        CobaltColumn(id: 20, name: "UntimedEvent", type: 0x0B, maxSize: 1),
        CobaltColumn(id: 30, name: "StartDateTime", type: 0x12, maxSize: 4),
        CobaltColumn(id: 40, name: "EndDateTime", type: 0x12, maxSize: 4),
        CobaltColumn(id: 50, name: "Timezone", type: 0x10, maxSize: 0x20),
        CobaltColumn(id: 100, name: "TimeAdvance", type: 0x05, maxSize: 1),
        CobaltColumn(id: 110, name: "TimeAdvanceUnit", type: 0x01, maxSize: 1),
        CobaltColumn(id: 200, name: "RepeatType", type: 0x01, maxSize: 1),
        CobaltColumn(id: 210, name: "RepeatEndDate", type: 0x12, maxSize: 4),
        CobaltColumn(id: 220, name: "RepeatFrequency", type: 0x01, maxSize: 1),
        CobaltColumn(id: 230, name: "RepeatOn", type: 0x01, maxSize: 1),
        CobaltColumn(id: 240, name: "RepeatStartOfWeek", type: 0x01, maxSize: 1),
        CobaltColumn(id: 300, name: "ExceptionsDates", type: 0x92, maxSize: 0xFFFF),
        CobaltColumn(id: 400, name: "Description", type: 0x10, maxSize: 0x100),
        CobaltColumn(id: 410, name: "Location", type: 0x10, maxSize: 0x100),
        CobaltColumn(id: 420, name: "Note", type: 0x10, maxSize: 0xFFFE),
    ]

    public static let toDo: [CobaltColumn] = [
        CobaltColumn(id: 100, name: "DueDate", type: 0x0D, maxSize: 2),
        CobaltColumn(id: 200, name: "Priority", type: 0x05, maxSize: 1),
        CobaltColumn(id: 300, name: "Description", type: 0x10, maxSize: 0x100),
        CobaltColumn(id: 400, name: "Note", type: 0x10, maxSize: 0xFFFE),
        CobaltColumn(id: 500, name: "Completed", type: 0x0B, maxSize: 1),
    ]

    /// The 59 columns; "Cutsom4" is the ROM's own spelling.
    public static let address: [CobaltColumn] = {
        func text(_ id: UInt32, _ name: String, attrib: Int = 0) -> CobaltColumn {
            CobaltColumn(id: id, name: name, type: 0x10, maxSize: 0x100, attrib: attrib)
        }
        return [
            text(100, "Title"), text(200, "LastName"), text(300, "MiddleName"), text(400, "FirstName"),
            text(500, "Suffix"), text(600, "NickName"), text(700, "Profession"),
            text(800, "Phone"), text(900, "Mobile"), text(1000, "Fax"),
            text(1100, "Email1"), text(1200, "Email2"), text(1300, "Email3"),
            text(1400, "HomeAddress"), text(1500, "HomeCity"), text(1600, "HomeState"), text(1700, "HomeZipCode"),
            text(1800, "Country"),
            CobaltColumn(id: 1900, name: "Anniversary", type: 0x0D, maxSize: 2),
            CobaltColumn(id: 2000, name: "Birthday", type: 0x0D, maxSize: 2),
            text(3000, "WorkCompany"), text(3100, "WorkTitle"),
            text(3200, "WorkAddress"), text(3300, "WorkCity"), text(3400, "WorkState"), text(3500, "WorkZipCode"),
            text(3600, "WorkCountry"),
            text(3700, "WorkPhone"), text(3800, "WorkMobile"), text(3900, "WorkFax"), text(4000, "WorkEmail"),
            text(4100, "AssistantName"), text(4200, "AssistantPhone"),
            text(6000, "OtherStreet"), text(6100, "OtherCity"), text(6200, "OtherState"), text(6300, "OtherZipCode"),
            text(6400, "OtherCountry"),
            text(6500, "OtherPhone"), text(6600, "OtherMobile"), text(6700, "OtherFax"), text(6800, "OtherPager"),
            text(6900, "Custom1"), text(7000, "Custom2"), text(7100, "Custom3"), text(7200, "Cutsom4"),
            text(7500, "OtherICQ", attrib: 2), text(7600, "OtherAIM", attrib: 2), text(7700, "OtherYahoo", attrib: 2),
            text(7800, "OtherMSN", attrib: 2), text(7900, "OtherJabber", attrib: 2), text(8500, "OtherURL", attrib: 2),
            CobaltColumn(id: 9000, name: "Note", type: 0x10, maxSize: 0xFFFE),
            CobaltColumn(id: 9100, name: "DisplayPhone", type: 0x03, maxSize: 4),
            CobaltColumn(id: 9200, name: "LastViewedTabID", type: 0x02, maxSize: 2, attrib: 2),
            text(10000, "YomiLastName", attrib: 2), text(10100, "YomiFirstName", attrib: 2),
            text(10200, "YomiCompany", attrib: 2), text(11000, "EnglishName", attrib: 2),
        ]
    }()

    public static let addressAppInfo: [CobaltColumn] = [
        CobaltColumn(id: 100, name: "Country", type: 0x02, maxSize: 2),
    ]

    /// The expected columns of a kind's main table.
    public static func columns(for kind: PalmPIMFamily.Kind) -> [CobaltColumn] {
        switch kind {
        case .calendar: return dateBook
        case .contacts: return address
        case .tasks: return toDo
        case .memos: return memo
        }
    }

    public static func table(for kind: PalmPIMFamily.Kind) -> String {
        switch kind {
        case .calendar: return dateBookTable
        case .contacts: return addressTable
        case .tasks: return toDoTable
        case .memos: return memoTable
        }
    }
}

// MARK: - Schema verification

/// Why a database's columns are not the ones the converters read.
public enum CobaltSchemaMismatch: Equatable, Sendable, CustomStringConvertible {
    case missing(CobaltColumn)
    case typeDiffers(id: UInt32, name: String, expected: UInt8, actual: UInt8)
    case sizeDiffers(id: UInt32, name: String, expected: Int, actual: Int)
    /// a column the device has and the layout does not: the converters
    /// would leave it alone, but a changed schema should be looked at
    case unexpected(CobaltColumn)

    public var description: String {
        switch self {
        case .missing(let c):
            return "column \(c.name) (\(c.id)) is missing"
        case .typeDiffers(let id, let name, let expected, let actual):
            return "column \(name) (\(id)) has type 0x\(String(actual, radix: 16)), expected 0x\(String(expected, radix: 16))"
        case .sizeDiffers(let id, let name, let expected, let actual):
            return "column \(name) (\(id)) has size \(actual), expected \(expected)"
        case .unexpected(let c):
            return "column \(c.name) (\(c.id), type 0x\(String(c.type, radix: 16))) is not in the known layout"
        }
    }
}

public enum CobaltSchemaCheck {
    /// The ways `actual` differs from `expected` in ids, types and sizes
    /// (names and attributes are not compared: the ids carry the meaning).
    /// Empty: the converters can read the table.
    public static func verify(_ actual: [CobaltColumn], against expected: [CobaltColumn]) -> [CobaltSchemaMismatch] {
        var mismatches: [CobaltSchemaMismatch] = []
        let byId = Dictionary(actual.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in expected {
            guard let a = byId[e.id] else {
                mismatches.append(.missing(e))
                continue
            }
            if a.type != e.type { mismatches.append(.typeDiffers(id: e.id, name: e.name, expected: e.type, actual: a.type)) }
            if a.maxSize != e.maxSize { mismatches.append(.sizeDiffers(id: e.id, name: e.name, expected: e.maxSize, actual: a.maxSize)) }
        }
        let known = Set(expected.map(\.id))
        for a in actual where !known.contains(a.id) { mismatches.append(.unexpected(a)) }
        return mismatches
    }

    /// The main table of `kind` against the T|X's layout.
    public static func verify(_ actual: [CobaltColumn], kind: PalmPIMFamily.Kind) -> [CobaltSchemaMismatch] {
        verify(actual, against: CobaltSchema.columns(for: kind))
    }
}

// MARK: - Converters (Cobalt row -> Garnet record), section 5 of the note

public enum CobaltRecords {
    // MARK: 5.1 Memo

    public enum MemoColumn {
        public static let text: UInt32 = 100
    }

    /// `MemoText` as the memo's text (the trailing NUL dropped).
    public static func memo(_ row: CobaltRow, schema: [CobaltColumn] = CobaltSchema.memo) -> CobaltConverted<PalmMemo> {
        var r = CobaltRowReader(row: row, schema: schema)
        let text = r.string(MemoColumn.text) ?? ""
        return CobaltConverted(record: PalmMemo(text: text), warnings: r.finish())
    }

    // MARK: 5.2 Calendar

    public enum DateBookColumn {
        public static let repeating: UInt32 = 10
        public static let untimed: UInt32 = 20
        public static let start: UInt32 = 30
        public static let end: UInt32 = 40
        public static let timezone: UInt32 = 50
        public static let alarmAdvance: UInt32 = 100
        public static let alarmUnit: UInt32 = 110
        public static let repeatType: UInt32 = 200
        public static let repeatEnd: UInt32 = 210
        public static let repeatFrequency: UInt32 = 220
        public static let repeatOn: UInt32 = 230
        public static let repeatStartOfWeek: UInt32 = 240
        public static let exceptions: UInt32 = 300
        public static let description: UInt32 = 400
        public static let location: UInt32 = 410
        public static let note: UInt32 = 420
    }

    /// A DateBookDBSchema row as a Calendar record. The event's day and
    /// times come from StartDateTime/EndDateTime read per
    /// `cobaltDateTimeInterpretation` in the zone the Timezone column names
    /// (an IANA name such as "US/Central"); the Garnet record carries no
    /// time zone blob (device local time). An untimed event has no time
    /// span. TimeAdvance -1 (0xFF) is no alarm. RepeatType 0 is no repeat,
    /// 1-5 the Garnet types; RepeatEndDate 0x7FFFFFFF repeats forever.
    public static func calendarEvent(_ row: CobaltRow, schema: [CobaltColumn] = CobaltSchema.dateBook) -> CobaltConverted<CalendarEvent>? {
        var r = CobaltRowReader(row: row, schema: schema)
        let zoneName = r.string(DateBookColumn.timezone)
        let zone = zoneName.flatMap { TimeZone(identifier: $0) }
        if let zoneName, zone == nil, cobaltDateTimeInterpretation == .utc {
            r.warn("row \(row.rowId): time zone \"\(zoneName)\" is unknown, the Mac's is used")
        }
        guard let startDate = r.dateTime(DateBookColumn.start) else {
            _ = r.finish()
            return nil   // an event without a start is not an event
        }
        let start = cobaltDateTimeComponents(startDate, zone: zone)
        let end = r.dateTime(DateBookColumn.end).map { cobaltDateTimeComponents($0, zone: zone) } ?? start
        let untimed = r.bool(DateBookColumn.untimed) ?? false

        var event = CalendarEvent(date: start.date, time: untimed ? nil : .init(start: start.time, end: end.time),
                                  title: r.string(DateBookColumn.description), note: r.string(DateBookColumn.note),
                                  location: r.string(DateBookColumn.location))

        if let advance = r.int8(DateBookColumn.alarmAdvance), advance >= 0 {
            let unitByte = r.uint8(DateBookColumn.alarmUnit) ?? 0
            if let unit = CalendarEvent.AlarmUnit(rawValue: unitByte) {
                event.alarm = .init(advance: UInt8(advance), unit: unit)
            } else {
                r.warn("row \(row.rowId): alarm unit \(unitByte) is unknown, alarm dropped")
            }
        } else {
            _ = r.uint8(DateBookColumn.alarmUnit)
        }

        let repeating = r.bool(DateBookColumn.repeating) ?? false
        let typeByte = r.uint8(DateBookColumn.repeatType) ?? 0
        let repeatEnd = r.dateTime(DateBookColumn.repeatEnd)
        let frequency = r.uint8(DateBookColumn.repeatFrequency)
        let on = r.uint8(DateBookColumn.repeatOn)
        let weekStart = r.uint8(DateBookColumn.repeatStartOfWeek)
        if typeByte != 0 {
            if let type = CalendarEvent.RepeatType(rawValue: typeByte) {
                event.repeatRule = .init(type: type, endDate: repeatEnd.map { cobaltDateTimeComponents($0, zone: zone).date },
                                         frequency: max(1, frequency ?? 1), on: on ?? 0, weekStart: weekStart ?? 0)
            } else {
                r.warn("row \(row.rowId): repeat type \(typeByte) is unknown, repeat dropped")
            }
        } else if repeating {
            r.warn("row \(row.rowId): RepeatingEvent is set but RepeatType is none")
        }

        event.exceptions = r.vector(DateBookColumn.exceptions, elementSize: 4).compactMap { element in
            cobaltDateTime(element).map { cobaltDateTimeComponents($0, zone: zone).date }
        }
        return CobaltConverted(record: event, warnings: r.finish())
    }

    // MARK: 5.3 Tasks

    public enum ToDoColumn {
        public static let dueDate: UInt32 = 100
        public static let priority: UInt32 = 200
        public static let description: UInt32 = 300
        public static let note: UInt32 = 400
        public static let completed: UInt32 = 500
    }

    /// A ToDoDBSchema row as a Tasks record. Cobalt keeps only a completed
    /// flag: a completed task gets `completedOn` (the sync day) as its
    /// completion date. Priority is clamped to 1-5.
    public static func task(_ row: CobaltRow, schema: [CobaltColumn] = CobaltSchema.toDo,
                            completedOn: PalmDate = PalmDate(Date(), in: .current)) -> CobaltConverted<PalmTask> {
        var r = CobaltRowReader(row: row, schema: schema)
        let priority = r.int8(ToDoColumn.priority).map { UInt8(clamping: min(max(Int($0), 1), 5)) } ?? 1
        let completed = r.bool(ToDoColumn.completed) ?? false
        let task = PalmTask(title: r.string(ToDoColumn.description) ?? "", note: r.string(ToDoColumn.note) ?? "",
                            priority: priority, dueDate: r.date(ToDoColumn.dueDate),
                            completedDate: completed ? completedOn : nil)
        return CobaltConverted(record: task, warnings: r.finish())
    }

    // MARK: 5.4 Contacts

    public enum AddressColumn {
        public static let prefix: UInt32 = 100, lastName: UInt32 = 200, middleName: UInt32 = 300, firstName: UInt32 = 400
        public static let suffix: UInt32 = 500, nickName: UInt32 = 600, profession: UInt32 = 700
        public static let homePhone: UInt32 = 800, homeMobile: UInt32 = 900, homeFax: UInt32 = 1000
        public static let email1: UInt32 = 1100, email2: UInt32 = 1200, email3: UInt32 = 1300
        public static let homeStreet: UInt32 = 1400, homeCity: UInt32 = 1500, homeState: UInt32 = 1600
        public static let homeZip: UInt32 = 1700, homeCountry: UInt32 = 1800
        public static let anniversary: UInt32 = 1900, birthday: UInt32 = 2000
        public static let company: UInt32 = 3000, title: UInt32 = 3100
        public static let workStreet: UInt32 = 3200, workCity: UInt32 = 3300, workState: UInt32 = 3400
        public static let workZip: UInt32 = 3500, workCountry: UInt32 = 3600
        public static let workPhone: UInt32 = 3700, workMobile: UInt32 = 3800, workFax: UInt32 = 3900, workEmail: UInt32 = 4000
        public static let assistantName: UInt32 = 4100, assistantPhone: UInt32 = 4200
        public static let otherStreet: UInt32 = 6000, otherCity: UInt32 = 6100, otherState: UInt32 = 6200
        public static let otherZip: UInt32 = 6300, otherCountry: UInt32 = 6400
        public static let otherPhone: UInt32 = 6500, otherMobile: UInt32 = 6600, otherFax: UInt32 = 6700, otherPager: UInt32 = 6800
        public static let custom1: UInt32 = 6900, custom2: UInt32 = 7000, custom3: UInt32 = 7100, custom4: UInt32 = 7200
        public static let icq: UInt32 = 7500, aim: UInt32 = 7600, yahoo: UInt32 = 7700, msn: UInt32 = 7800, jabber: UInt32 = 7900
        public static let url: UInt32 = 8500
        public static let note: UInt32 = 9000
        public static let displayPhone: UInt32 = 9100, lastViewedTab: UInt32 = 9200
        public static let yomiLastName: UInt32 = 10000, yomiFirstName: UInt32 = 10100, yomiCompany: UInt32 = 10200
        public static let englishName: UInt32 = 11000

        /// UI state and the Japanese reading columns: never carried, never
        /// reported as dropped.
        public static let ignored: Set<UInt32> = [lastViewedTab, yomiLastName, yomiFirstName, yomiCompany, englishName]
    }

    /// The phone-like columns in the order they fill the seven Garnet phone
    /// slots (section 5.4's policy): the three phones, the mobiles, the
    /// faxes, the e-mails, the pager, the assistant's phone.
    public static let phoneSlotOrder: [(column: UInt32, label: ContactsBuilder.PhoneLabel)] = [
        (AddressColumn.homePhone, .home), (AddressColumn.workPhone, .work), (AddressColumn.otherPhone, .other),
        (AddressColumn.homeMobile, .mobile), (AddressColumn.workMobile, .mobile), (AddressColumn.otherMobile, .mobile),
        (AddressColumn.homeFax, .fax), (AddressColumn.workFax, .fax), (AddressColumn.otherFax, .fax),
        (AddressColumn.email1, .email), (AddressColumn.email2, .email), (AddressColumn.email3, .email),
        (AddressColumn.workEmail, .email),
        (AddressColumn.otherPager, .pager),
        (AddressColumn.assistantPhone, .other),
    ]

    /// The IM columns in the order they fill the two Garnet IM slots.
    public static let imSlotOrder: [(column: UInt32, label: ContactsBuilder.IMLabel)] = [
        (AddressColumn.aim, .aim), (AddressColumn.msn, .msn), (AddressColumn.yahoo, .yahoo),
        (AddressColumn.icq, .icq), (AddressColumn.jabber, .other),
    ]

    private static let addressGroups: [(columns: (UInt32, UInt32, UInt32, UInt32, UInt32), label: ContactsBuilder.AddressLabel)] = [
        ((AddressColumn.homeStreet, AddressColumn.homeCity, AddressColumn.homeState, AddressColumn.homeZip, AddressColumn.homeCountry), .home),
        ((AddressColumn.workStreet, AddressColumn.workCity, AddressColumn.workState, AddressColumn.workZip, AddressColumn.workCountry), .work),
        ((AddressColumn.otherStreet, AddressColumn.otherCity, AddressColumn.otherState, AddressColumn.otherZip, AddressColumn.otherCountry), .other),
    ]

    private static let garnetPhoneFields: [Contact.Field] = [.phone1, .phone2, .phone3, .phone4, .phone5, .phone6, .phone7]
    private static let garnetAddressFields: [(Contact.Field, Contact.Field, Contact.Field, Contact.Field, Contact.Field)] = [
        (.address1, .city1, .state1, .zip1, .country1),
        (.address2, .city2, .state2, .zip2, .country2),
        (.address3, .city3, .state3, .zip3, .country3),
    ]

    /// An AddressBookDBSchema row as a Contacts record. Names, company and
    /// title map 1:1; the phone-like columns fill phone1-7 in
    /// `phoneSlotOrder` with their label, the rest are dropped (a warning
    /// each); the home, work and other addresses take the three address
    /// slots in that order (empty ones skipped); AIM, MSN, Yahoo, ICQ,
    /// Jabber fill the two IM slots; URL, Custom1-4, Note and Birthday map
    /// directly; Anniversary becomes the "Bd01" blob; DisplayPhone picks
    /// the shown phone. Prefix, middle name, suffix, nickname, profession
    /// and the assistant's name have no Garnet field and are reported as
    /// not carried; Yomi names and LastViewedTabID are UI/locale state and
    /// stay quiet.
    public static func contact(_ row: CobaltRow, schema: [CobaltColumn] = CobaltSchema.address) -> CobaltConverted<Contact> {
        var r = CobaltRowReader(row: row, schema: schema)
        var c = Contact()
        c[.lastName] = r.string(AddressColumn.lastName)
        c[.firstName] = r.string(AddressColumn.firstName)
        c[.company] = r.string(AddressColumn.company)
        c[.title] = r.string(AddressColumn.title)

        // phones: the slots in policy order, each with its label
        var filled: [(column: UInt32, label: ContactsBuilder.PhoneLabel)] = []
        for slot in phoneSlotOrder {
            guard let value = r.string(slot.column) else { continue }
            if filled.count < garnetPhoneFields.count {
                c[garnetPhoneFields[filled.count]] = value
                c.setPhoneLabel(filled.count, slot.label.rawValue)
                filled.append(slot)
            } else {
                r.warn("row \(row.rowId): \(schema.first { $0.id == slot.column }?.name ?? "column \(slot.column)") dropped, the Garnet record holds 7 phones")
            }
        }
        if let display = r.uint32(AddressColumn.displayPhone), let shown = filled.firstIndex(where: { $0.column == display }) {
            c.showPhone = UInt8(shown)
        }

        // addresses: home, work, other into the three slots, empty ones skipped
        var addressSlot = 0
        for group in addressGroups {
            let values = (r.string(group.columns.0), r.string(group.columns.1), r.string(group.columns.2),
                          r.string(group.columns.3), r.string(group.columns.4))
            guard values.0 != nil || values.1 != nil || values.2 != nil || values.3 != nil || values.4 != nil else { continue }
            let f = garnetAddressFields[addressSlot]
            c[f.0] = values.0
            c[f.1] = values.1
            c[f.2] = values.2
            c[f.3] = values.3
            c[f.4] = values.4
            c.setAddressLabel(addressSlot, group.label.rawValue)
            addressSlot += 1
        }

        // instant messaging and the web
        var imSlot = 0
        for slot in imSlotOrder {
            guard let value = r.string(slot.column) else { continue }
            if imSlot < 2 {
                c[imSlot == 0 ? .im1 : .im2] = value
                c.setIMLabel(imSlot, slot.label.rawValue)
                imSlot += 1
            } else {
                r.warn("row \(row.rowId): \(schema.first { $0.id == slot.column }?.name ?? "column \(slot.column)") dropped, the Garnet record holds 2 IM names")
            }
        }
        c[.website] = r.string(AddressColumn.url)

        c[.custom1] = r.string(AddressColumn.custom1)
        c[.custom2] = r.string(AddressColumn.custom2)
        c[.custom3] = r.string(AddressColumn.custom3)
        c[.custom4] = r.string(AddressColumn.custom4)
        c[.note] = r.string(AddressColumn.note)

        if let birthday = r.date(AddressColumn.birthday) {
            c.birthday = .init(date: birthday, reminderAdvance: nil, advanceUnits: 0)
        }
        if let anniversary = r.date(AddressColumn.anniversary) {
            c.blobs.append(anniversaryBlob(anniversary))
        }
        return CobaltConverted(record: c, warnings: r.finish(ignoring: AddressColumn.ignored))
    }

    /// The Contacts application's anniversary blob ("Bd01"): a flag word
    /// (0), then the packed date, big-endian, as DateFix reads it.
    public static func anniversaryBlob(_ date: PalmDate) -> PalmBlob {
        let packed = date.packed
        return PalmBlob(type: Contact.anniversaryBlobType, data: Data([0, 0, UInt8(packed >> 8), UInt8(packed & 0xFF)]))
    }

    /// The anniversary a contact's "Bd01" blob holds, if any.
    public static func anniversary(of contact: Contact) -> PalmDate? {
        guard let blob = contact.blobs.first(where: { $0.type == Contact.anniversaryBlobType }), blob.data.count >= 4 else { return nil }
        let bytes = [UInt8](blob.data)
        let packed = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        return packed == PalmDate.none ? nil : PalmDate(packed: packed)
    }

    // MARK: Row attributes (section 5.5)

    /// The engine's record attributes for a row: deleted 0x80, archived
    /// 0x08 and dirty 0x40 (from the sync status's modified bits; Cobalt
    /// has no dirty flag of its own).
    public static func recordAttributes(of row: CobaltRow) -> UInt8 {
        var attributes: UInt8 = 0
        if row.deleted { attributes |= 0x80 }
        if row.modified { attributes |= 0x40 }
        if row.archived { attributes |= 0x08 }
        return attributes
    }
}
