import Foundation
import Testing
import HotSyncCore
@testable import PalmSync

// The read of one Cobalt PIM database as the app drives it: the commands
// CobaltDatabaseReader asks for, in order, and what it makes of the answers.

private func event(_ line: String) -> SessionEvent {
    SessionEvent.parse(line) ?? { Issue.record("not an event: \(line)"); return .progress(bytes: 0) }()
}

/// The T|X's column events of one table, from the step 2 fixture, with the
/// handle the fixture used (MemoDBS was opened twice there: handles 4 and 5).
private func fixtureColumns(table: String, handle: Int) throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: "cobalt-schema-tx", withExtension: "jsonl", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        .filter { $0.contains("\"table\": \"\(table)\"") && $0.contains("\"handle\": \(handle),") }
}

private let memoRow = """
    {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 2160361473, "attr": 0, "syncStatus": 3, \
    "modified": 1, "deleted": 0, "archived": 0, "present": 1, "err": 0, "categories": [17], \
    "columns": [{"id": 100, "size": 6, "err": 0, "hex": "68656c6c6f00"}]}
    """
private let deletedMemoRow = """
    {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 2160361474, "attr": 128, "syncStatus": 4, \
    "modified": 0, "deleted": 1, "archived": 0, "present": 1, "err": 0, "categories": [], "columns": []}
    """

// MARK: - The family

@Test func cobaltIsAFamilyOfSchemaDatabases() throws {
    let f = PalmPIMFamily.cobalt
    #expect(f.isSchema && !PalmPIMFamily.garnet.isSchema && !PalmPIMFamily.classic.isSchema)
    #expect(f.databaseName(.calendar) == "DateBookDBS" && f.creator(.calendar) == "dats")
    #expect(f.databaseName(.contacts) == "AddressDBS" && f.creator(.contacts) == "adrs")
    #expect(f.databaseName(.tasks) == "ToDoDBS" && f.creator(.tasks) == "tdos")
    #expect(f.databaseName(.memos) == "MemoDBS" && f.creator(.memos) == "mems")
    #expect(PalmPIMFamily.kind(ofDatabase: "ToDoDBS") == .tasks)
    #expect(PalmPIMFamily.family(ofDatabase: "MemoDBS") == .cobalt)
    #expect(PalmPIMFamily.family(ofDatabase: "MemosDB-PMem") == .garnet)
    #expect(f.memoTextLimit == 65533)
    // once read, the rows are Garnet records: the byte functions leave them alone
    let memo = PalmMemo(text: "hi").encode()
    #expect(try f.garnetRecord(memo, kind: .memos) == memo)
    #expect(f.readsBack(CalendarEvent(date: PalmDate(year: 2026, month: 1, day: 2), title: "x").encode(), kind: .calendar))
}

// MARK: - The reader

@Test func readerReadsAMemoDatabase() throws {
    var reader = CobaltDatabaseReader(kind: .memos)
    #expect(reader.openCommand == "cobaltopen MemoDBS mems 1")
    #expect(reader.step == .opening)

    // not this read's business
    #expect(reader.handle(event(#"{"event":"progress","bytes":7}"#)) == .wait)

    #expect(reader.handle(event(#"{"event": "cobaltOpened", "handle": 4, "name": "MemoDBS", "creator": "mems", "mode": 1}"#))
            == .send("cobaltschema 4 MemoDBSchema"))
    for line in try fixtureColumns(table: "MemoDBSchema", handle: 4) {
        #expect(reader.handle(event(line)) == .wait)
    }
    #expect(reader.handle(event(#"{"event": "cobaltSchemaDone", "handle": 4, "table": "MemoDBSchema", "count": 1}"#))
            == .send("cobaltcategories 4"))
    #expect(reader.mismatches.isEmpty)
    #expect(reader.handle(event(#"{"event": "cobaltCategory", "handle": 4, "id": 16, "name": "Business"}"#)) == .wait)
    #expect(reader.handle(event(#"{"event": "cobaltCategory", "handle": 4, "id": 17, "name": "Personal"}"#)) == .wait)
    #expect(reader.handle(event(#"{"event": "cobaltCategoriesDone", "handle": 4, "count": 2}"#))
            == .send("cobaltreadall 4 MemoDBSchema"))
    #expect(reader.handle(event(memoRow)) == .wait)
    #expect(reader.handle(event(deletedMemoRow)) == .wait)
    #expect(reader.handle(event(#"{"event": "cobaltRowsDone", "handle": 4, "table": "MemoDBSchema", "rows": 2, "tables": 1}"#))
            == .send("cobaltclose 4 0"))
    #expect(reader.step == .closing)
    #expect(reader.handle(event(#"{"event": "cobaltClosed", "handle": 4, "name": "MemoDBS"}"#)) == .finished)
    #expect(reader.isDone && reader.failure == nil)

    let read = try #require(reader.result)
    #expect(read.rows.count == 2 && read.records.count == 2 && read.skipped.isEmpty && read.warnings.isEmpty)
    let memo = read.records[0]
    #expect(memo.id == 0x80C4_8001)
    #expect(try PalmMemo(data: memo.data).text == "hello")
    #expect(memo.category == 2)              // Unfiled 0, Business 1, Personal 2
    #expect(memo.attributes == 0x40)         // modified -> dirty
    let deleted = read.records[1]
    #expect(deleted.isDeleted && deleted.data.isEmpty && deleted.category == 0)
    // the categories as the app reads them from a Garnet database's AppInfo
    let categories = PalmPIMFamily.cobalt.categories(ofAppInfo: read.appInfo, kind: .memos)
    #expect(categories?.named.map(\.name) == ["Unfiled", "Business", "Personal"])
}

@Test func readerRefusesADatabaseWhoseSchemaDiffers() throws {
    var reader = CobaltDatabaseReader(kind: .tasks)
    #expect(reader.handle(event(#"{"event": "cobaltOpened", "handle": 3, "name": "ToDoDBS", "creator": "tdos", "mode": 1}"#))
            == .send("cobaltschema 3 ToDoDBSchema"))
    for line in try fixtureColumns(table: "ToDoDBSchema", handle: 3) {
        // Priority as a UInt16 instead of the Int8 the T|X has
        let changed = line.replacingOccurrences(of: #""name": "Priority", "type": 5"#, with: #""name": "Priority", "type": 2"#)
        #expect(reader.handle(event(changed)) == .wait)
    }
    #expect(reader.handle(event(#"{"event": "cobaltSchemaDone", "handle": 3, "table": "ToDoDBSchema", "count": 5}"#))
            == .send("cobaltclose 3 0"))
    #expect(reader.mismatches == [.typeDiffers(id: 200, name: "Priority", expected: 5, actual: 2)])
    #expect(reader.failure?.contains("ToDoDBSchema") == true)
    #expect(reader.handle(event(#"{"event": "cobaltClosed", "handle": 3, "name": "ToDoDBS"}"#)) == .finished)
    #expect(reader.result == nil && reader.isDone)
}

@Test func readerEndsOnAnOpenError() {
    var reader = CobaltDatabaseReader(kind: .contacts)
    // the Palm refused (secure database, error 25 would be "trust required")
    #expect(reader.handle(event(#"{"event":"error","stage":"cobaltopen","message":"Palm OS error 25"}"#)) == .finished)
    #expect(reader.isDone && reader.result == nil && reader.failure == "cobaltopen: Palm OS error 25")
    // other errors are not this read's
    var fresh = CobaltDatabaseReader(kind: .contacts)
    #expect(fresh.handle(event(#"{"event":"error","stage":"opendb","message":"x"}"#)) == .wait)
}

@Test func readerClosesAfterAReadError() {
    var reader = CobaltDatabaseReader(kind: .calendar)
    #expect(reader.handle(event(#"{"event": "cobaltOpened", "handle": 2, "name": "DateBookDBS", "creator": "dats", "mode": 1}"#))
            == .send("cobaltschema 2 DateBookDBSchema"))
    for column in CobaltSchema.dateBook {
        #expect(reader.handle(.cobalt(.column(handle: 2, table: "DateBookDBSchema", column))) == .wait)
    }
    #expect(reader.handle(.cobalt(.schemaDone(handle: 2, table: "DateBookDBSchema", count: 16))) == .send("cobaltcategories 2"))
    #expect(reader.handle(.cobalt(.categoriesDone(handle: 2, count: 0))) == .send("cobaltreadall 2 DateBookDBSchema"))
    // a result over one message (open question 2): the tool reports it as an error
    #expect(reader.handle(.error(stage: "cobaltreadall", message: "more follows (0x8000)")) == .send("cobaltclose 2 0"))
    #expect(reader.handle(.cobalt(.closed(handle: 2, name: "DateBookDBS", token: nil))) == .finished)
    #expect(reader.result == nil && reader.failure == "cobaltreadall: more follows (0x8000)")
}

@Test func readerIgnoresAnswersOfAnotherHandle() {
    var reader = CobaltDatabaseReader(kind: .memos)
    #expect(reader.handle(.cobalt(.opened(handle: 4, name: "MemoDBS", creator: "mems", mode: 1))) == .send("cobaltschema 4 MemoDBSchema"))
    #expect(reader.handle(.cobalt(.column(handle: 5, table: "MemoDBSchema", CobaltSchema.memo[0]))) == .wait)
    #expect(reader.columns.isEmpty)
    #expect(reader.handle(.cobalt(.schemaDone(handle: 5, table: "MemoDBSchema", count: 1))) == .wait)
    #expect(reader.step == .schema)
}

// MARK: - Rows as engine records

@Test func calendarRowWithoutAStartMakesNoRecord() {
    let categories = CobaltCategoryMap([CobaltCategory(id: 16, name: "Business")])
    let bare = CobaltRow(rowId: 0x8000_0001, syncStatus: 1, categories: [16],
                         columns: [CobaltRecords.DateBookColumn.description: Data("Lunch\0".utf8)])
    let none = CobaltRecords.palmRecord(of: bare, kind: .calendar, schema: CobaltSchema.dateBook, categories: categories)
    #expect(none.record == nil && !none.warnings.isEmpty)

    // 2026-03-04 12:00 wall clock as seconds since 1970
    var start = UInt32(1_772_625_600).littleEndian
    let startBytes = Data(bytes: &start, count: 4)
    let timed = CobaltRow(rowId: 0x8000_0002, syncStatus: 1, categories: [16],
                          columns: [CobaltRecords.DateBookColumn.start: startBytes, CobaltRecords.DateBookColumn.end: startBytes,
                                    CobaltRecords.DateBookColumn.description: Data("Lunch\0".utf8)])
    let some = CobaltRecords.palmRecord(of: timed, kind: .calendar, schema: CobaltSchema.dateBook, categories: categories)
    let record = some.record ?? nil
    #expect(record?.category == 1 && record?.attributes == 0x40)
    #expect((try? CalendarEvent(data: record?.data ?? Data()))?.title == "Lunch")

    let read = CobaltDatabaseRead(kind: .calendar, columns: CobaltSchema.dateBook,
                                  categories: [CobaltCategory(id: 16, name: "Business")], rows: [bare, timed])
    #expect(read.records.count == 1 && read.skipped == [0x8000_0001])
    #expect(read.warnings.first?.hasPrefix("row 0x80000001: ") == true)
}

@Test func garnetAppInfoOfEveryKindDecodes() {
    let categories = CobaltCategoryMap([CobaltCategory(id: 16, name: "Business"), CobaltCategory(id: 18, name: "QuickList")]).appInfo
    for kind in PalmPIMFamily.Kind.allCases {
        let data = CobaltDatabaseRead.garnetAppInfo(categories, kind: kind)
        #expect(PalmPIMFamily.cobalt.categories(ofAppInfo: data, kind: kind)?.named.map(\.name) == ["Unfiled", "Business", "QuickList"],
                "\(kind)")
    }
}
