import Foundation
import HotSyncCore
import Testing
@testable import PalmSync

// Rows built from the documented column layouts (Planning/cobalt-pim.md,
// section 2.2) with little-endian device bytes, and the real bytes the
// T|X returned (the AddressBookAppInfo country row, the column lists).

private func hex(_ s: String) -> Data { Data(hex: s)! }

private func row(id: UInt32 = 0x80C4_8001, categories: [UInt32] = [], _ columns: [UInt32: String]) -> CobaltRow {
    CobaltRow(rowId: id, syncStatus: 3, categories: categories, columns: columns.mapValues { hex($0) })
}

// MARK: - Primitives

@Test func littleEndianScalarsDecode() {
    #expect(CobaltBytes.uint16(hex("3412")) == 0x1234)
    #expect(CobaltBytes.uint32(hex("78563412")) == 0x1234_5678)
    #expect(CobaltBytes.int8(hex("ff")) == -1)
    #expect(CobaltBytes.bool(hex("01")) == true)
    #expect(CobaltBytes.bool(hex("00")) == false)
    #expect(CobaltBytes.uint16(hex("12")) == nil)
    #expect(CobaltBytes.vector(hex("0102030405060708"), elementSize: 4) == [hex("01020304"), hex("05060708")])
    #expect(CobaltBytes.vector(hex("010203"), elementSize: 4) == [])
}

@Test func theCountryRowOfTheTXIsUS() {
    // AddressBookAppInfo column 100, bytes 53 55 as the T|X returned them
    #expect(cobaltCountryCode(hex("5355")) == "US")
    #expect(cobaltCountryCode(hex("0000")) == nil)
}

@Test func dateColumnsArePackedPalmDatesLittleEndian() {
    #expect(cobaltDate(hex("98f5")) == PalmDate(year: 2026, month: 12, day: 24))
    #expect(cobaltDate(hex("ffff")) == nil)
    #expect(cobaltDate(hex("0000")) == nil)
    #expect(cobaltDate(hex("98")) == nil)
}

@Test func dateTimeSecsCountFrom1970() {
    let date = cobaltDateTime(hex("10f5076b"))   // 1795683600
    #expect(date == Date(timeIntervalSince1970: 1_795_683_600))
    #expect(cobaltDateTime(hex("ffffff7f")) == nil)   // never
    let c = cobaltDateTimeComponents(date!, zone: TimeZone(identifier: "US/Central"))
    #expect(c.date == PalmDate(year: 2026, month: 11, day: 26))
    #expect(c.time == PalmTime(hour: 9, minute: 0))
}

@Test func varCharIsUTF8WithAWindows1252Fallback() {
    #expect(cobaltString(hex("68656c6c6f00")) == "hello")
    #expect(cobaltString(hex("68656c6c6f")) == "hello")   // no NUL
    #expect(cobaltString(hex("4361662900")) == "Caf)")
    #expect(cobaltString(hex("436166c3a900")) == "Café")  // UTF-8
    #expect(cobaltString(hex("436166e900")) == "Café")    // Windows-1252
    #expect(cobaltString(Data()) == "")
}

// MARK: - 5.1 Memo

@Test func memoRowBecomesAMemoInItsCategory() {
    let memo = row(categories: [0x11], [100: "68656c6c6f00"])
    let converted = CobaltRecords.memo(memo)
    #expect(converted.record == PalmMemo(text: "hello"))
    #expect(converted.warnings.isEmpty)

    let map = CobaltCategoryMap([CobaltCategory(id: 0x10, name: "Business"), CobaltCategory(id: 0x11, name: "Personal")])
    #expect(map.index(of: memo) == 2)
    #expect(map.name(of: 0x11) == "Personal")
    #expect(map.name(of: 0) == "Unfiled")
    #expect(map.name(of: 0x12) == nil)
    #expect(map.index(of: row(categories: [], [:])) == 0)
    #expect(map.index(of: row(categories: [0x99], [:])) == 0)
    #expect(map.cobaltId(ofIndex: 2) == 0x11)
    let appInfo = map.appInfo
    #expect(appInfo.names.prefix(3) == ["Unfiled", "Business", "Personal"])
    #expect(appInfo.ids.prefix(3) == [0, 0x10, 0x11])
    #expect(CobaltRecords.recordAttributes(of: memo) == 0x40)
}

@Test func unknownColumnsAreSkippedWithAWarning() {
    let memo = row([100: "6869", 200: "010203"])
    let converted = CobaltRecords.memo(memo)
    #expect(converted.record.text == "hi")
    #expect(converted.warnings == ["row 2160361473: column 200 is not in the schema, skipped"])

    let schema = CobaltSchema.memo + [CobaltColumn(id: 200, name: "Odd", type: 0x7F, maxSize: 3)]
    #expect(CobaltRecords.memo(memo, schema: schema).warnings == ["row 2160361473: Odd (200) has unknown type 0x7f, skipped"])
}

// MARK: - 5.2 Calendar

@Test func timedEventRowBecomesACalendarEvent() throws {
    let event = row([
        10: "00", 20: "00",
        30: "10f5076b", 40: "280a086b",      // 2026-11-26 09:00 - 10:30
        50: "55532f4365"+"6e7472616c00",     // "US/Central"
        100: "ff", 110: "00",                // no alarm
        200: "00", 210: "ffffff7f", 220: "00", 230: "00", 240: "00",
        400: "4c756e636800",                 // "Lunch"
        410: "4361666500",                   // "Cafe"
        420: "",
    ])
    let converted = try #require(CobaltRecords.calendarEvent(event))
    let e = converted.record
    #expect(e.date == PalmDate(year: 2026, month: 11, day: 26))
    #expect(e.time == .init(start: PalmTime(hour: 9, minute: 0), end: PalmTime(hour: 10, minute: 30)))
    #expect(e.title == "Lunch")
    #expect(e.location == "Cafe")
    #expect(e.note == nil)
    #expect(e.alarm == nil)
    #expect(e.repeatRule == nil)
    #expect(e.exceptions.isEmpty)
    #expect(e.blobs.isEmpty)
    #expect(converted.warnings.isEmpty)
    // the record is a Garnet record: it round-trips through the codec
    #expect(try CalendarEvent(data: e.encode()) == e)
}

@Test func untimedEventRowHasNoTime() throws {
    let event = row([20: "01", 30: "000e0e6b", 40: "000e0e6b", 400: "486f6c696461 7900".replacingOccurrences(of: " ", with: "")])
    let e = try #require(CobaltRecords.calendarEvent(event)).record
    #expect(e.date == PalmDate(year: 2026, month: 12, day: 1))
    #expect(e.time == nil)
    #expect(e.title == "Holiday")
}

@Test func eventWithoutAStartIsNotAnEvent() {
    #expect(CobaltRecords.calendarEvent(row([400: "7800"])) == nil)
}

@Test func repeatingEventRowKeepsRuleAlarmAndExceptions() throws {
    let event = row([
        10: "01", 20: "00",
        30: "10f5076b", 40: "280a086b",
        100: "0f", 110: "00",                // 15 minutes before
        200: "02", 210: "0042ac6b",          // weekly until 2027-03-31
        220: "01", 230: "2a", 240: "00",     // every week, Mon Wed Fri
        300: "1081126b" + "90bb1b6b",        // 2026-12-04 and 2026-12-11, 09:00
        400: "47796d00",
    ])
    let converted = try #require(CobaltRecords.calendarEvent(event))
    let e = converted.record
    #expect(e.alarm == .init(advance: 15, unit: .minutes))
    #expect(e.repeatRule == .init(type: .weekly, endDate: PalmDate(year: 2027, month: 3, day: 31), frequency: 1, on: 0x2A, weekStart: 0))
    #expect(e.repeatRule?.weekdays == [.monday, .wednesday, .friday])
    #expect(e.exceptions == [PalmDate(year: 2026, month: 12, day: 4), PalmDate(year: 2026, month: 12, day: 11)])
    #expect(converted.warnings.isEmpty)
    #expect(try CalendarEvent(data: e.encode()) == e)
}

@Test func foreverRepeatAndUnknownCodesAreHandled() throws {
    let forever = row([30: "10f5076b", 200: "01", 210: "ffffff7f", 400: "7800"])
    #expect(try #require(CobaltRecords.calendarEvent(forever)).record.repeatRule == .init(type: .daily, endDate: nil, frequency: 1))

    let odd = row([30: "10f5076b", 100: "05", 110: "09", 200: "07", 400: "7800"])
    let converted = try #require(CobaltRecords.calendarEvent(odd))
    #expect(converted.record.alarm == nil)
    #expect(converted.record.repeatRule == nil)
    #expect(converted.warnings.contains { $0.contains("alarm unit 9") })
    #expect(converted.warnings.contains { $0.contains("repeat type 7") })

    let short = row([30: "10f5", 400: "7800"])   // StartDateTime cut to two bytes
    #expect(CobaltRecords.calendarEvent(short) == nil)
}

// MARK: - 5.3 Tasks

@Test func taskRowBecomesAPalmTask() {
    let task = row([
        100: "98f5",                          // due 2026-12-24
        200: "03",
        300: "5461786573 00".replacingOccurrences(of: " ", with: ""),
        400: "4e6f746500",
        500: "01",
    ])
    let converted = CobaltRecords.task(task, completedOn: PalmDate(year: 2026, month: 11, day: 26))
    let t = converted.record
    #expect(t.title == "Taxes")
    #expect(t.note == "Note")
    #expect(t.priority == 3)
    #expect(t.dueDate == PalmDate(year: 2026, month: 12, day: 24))
    #expect(t.completedDate == PalmDate(year: 2026, month: 11, day: 26))
    #expect(t.isCompleted)
    #expect(converted.warnings.isEmpty)

    let open = CobaltRecords.task(row([100: "ffff", 200: "09", 300: "4f70656e00", 500: "00"])).record
    #expect(open.dueDate == nil)
    #expect(open.completedDate == nil)
    #expect(open.priority == 5)   // clamped
    #expect(open.note == "")
}

// MARK: - 5.4 Contacts

private let contactRow = row([
    200: "446f6500",                           // Doe
    400: "4a616e6500",                         // Jane
    300: "4d00",                               // middle name M: not carried
    3000: "41434d4500",                        // ACME
    3100: "43544f00",                          // CTO
    800: "3535352d3131313100",                 // home phone
    3700: "3535352d3232323200",                // work phone
    900: "3535352d3333333300",                 // home mobile
    1100: "6a616e65406578616d706c652e636f6d00", // jane@example.com
    6800: "3535352d3434343400",                // pager
    9100: "84030000",                          // DisplayPhone = 900 (the mobile)
    1400: "31204d61696e205374 00".replacingOccurrences(of: " ", with: ""),   // 1 Main St
    1500: "537072696e676669656c6400",          // Springfield
    6000: "506f204 26f78203100".replacingOccurrences(of: " ", with: ""),     // Po Box 1 (other address)
    7600: "6a616e6500",                        // AIM jane
    8500: "687474703a2f2f6a2e6578616d706c6500", // http://j.example
    6900: "6300",                              // Custom1 c
    9000: "4e6f746500",
    2000: "b198",                              // birthday 1980-05-17
    1900: "d2ca",                              // anniversary 2005-06-18
    9200: "0100",                              // LastViewedTabID: UI state
    10000: "e38389e3828600",                   // YomiLastName: locale
])

@Test func contactRowBecomesAContactWithPhoneSlotsByPolicy() throws {
    let converted = CobaltRecords.contact(contactRow)
    let c = converted.record
    #expect(c[.lastName] == "Doe")
    #expect(c[.firstName] == "Jane")
    #expect(c[.company] == "ACME")
    #expect(c[.title] == "CTO")

    // home phone, work phone, mobile, e-mail, pager: in policy order with labels
    #expect(c[.phone1] == "555-1111")
    #expect(c.phoneLabel(0) == ContactsBuilder.PhoneLabel.home.rawValue)
    #expect(c[.phone2] == "555-2222")
    #expect(c.phoneLabel(1) == ContactsBuilder.PhoneLabel.work.rawValue)
    #expect(c[.phone3] == "555-3333")
    #expect(c.phoneLabel(2) == ContactsBuilder.PhoneLabel.mobile.rawValue)
    #expect(c[.phone4] == "jane@example.com")
    #expect(c.phoneLabel(3) == ContactsBuilder.PhoneLabel.email.rawValue)
    #expect(c[.phone5] == "555-4444")
    #expect(c.phoneLabel(4) == ContactsBuilder.PhoneLabel.pager.rawValue)
    #expect(c[.phone6] == nil)
    #expect(c.showPhone == 2)   // DisplayPhone names the mobile

    // home address in slot 1, the other address compacted into slot 2
    #expect(c[.address1] == "1 Main St")
    #expect(c[.city1] == "Springfield")
    #expect(c.addressLabel(0) == ContactsBuilder.AddressLabel.home.rawValue)
    #expect(c[.address2] == "Po Box 1")
    #expect(c.addressLabel(1) == ContactsBuilder.AddressLabel.other.rawValue)
    #expect(c[.address3] == nil)

    #expect(c[.im1] == "jane")
    #expect(c.imLabel(0) == ContactsBuilder.IMLabel.aim.rawValue)
    #expect(c[.website] == "http://j.example")
    #expect(c[.custom1] == "c")
    #expect(c[.note] == "Note")
    #expect(c.birthday == .init(date: PalmDate(year: 1980, month: 5, day: 17), reminderAdvance: nil, advanceUnits: 0))
    #expect(CobaltRecords.anniversary(of: c) == PalmDate(year: 2005, month: 6, day: 18))

    // the middle name is reported, UI state and Yomi columns are not
    #expect(converted.warnings == ["row 2160361473: MiddleName (300) is not carried to the Mac"])
    #expect(try Contact(data: c.encode()) == c)
}

@Test func moreThanSevenPhonesAreDroppedWithAWarning() {
    var columns: [UInt32: String] = [200: "4100"]
    for (i, slot) in CobaltRecords.phoneSlotOrder.enumerated() {
        columns[slot.column] = String(format: "%02x00", 0x30 + i)   // "0", "1", … one digit each
    }
    let converted = CobaltRecords.contact(row(columns))
    #expect(converted.record[.phone7] == "6")
    #expect(converted.record[.phone1] == "0")
    #expect(converted.warnings.count == CobaltRecords.phoneSlotOrder.count - 7)
    #expect(converted.warnings.allSatisfy { $0.contains("dropped") })
}

// MARK: - Schema verification

@Test func theTXColumnListsPassTheVerifier() throws {
    let url = try #require(Bundle.module.url(forResource: "cobalt-schema-tx", withExtension: "jsonl", subdirectory: "Fixtures"))
    let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
    var tables: [String: [CobaltColumn]] = [:]
    for line in lines {
        guard case .cobalt(.column(_, let table, let column))? = SessionEvent.parse(String(line)) else {
            Issue.record("not a column event: \(line)")
            continue
        }
        tables[table, default: []].append(column)
    }
    #expect(tables.mapValues(\.count) == ["AddressBookDBSchema": 59, "AddressBookAppInfo": 1, "DateBookDBSchema": 16,
                                           "ToDoDBSchema": 5, "MemoDBSchema": 1])
    // the device's lists are exactly the constants (names and attributes included)
    #expect(tables[CobaltSchema.addressTable] == CobaltSchema.address)
    #expect(tables[CobaltSchema.addressAppInfoTable] == CobaltSchema.addressAppInfo)
    #expect(tables[CobaltSchema.dateBookTable] == CobaltSchema.dateBook)
    #expect(tables[CobaltSchema.toDoTable] == CobaltSchema.toDo)
    #expect(tables[CobaltSchema.memoTable] == CobaltSchema.memo)
    for kind in PalmPIMFamily.Kind.allCases {
        #expect(CobaltSchemaCheck.verify(tables[CobaltSchema.table(for: kind)] ?? [], kind: kind).isEmpty)
    }
    #expect(CobaltSchemaCheck.verify(tables[CobaltSchema.addressAppInfoTable] ?? [], against: CobaltSchema.addressAppInfo).isEmpty)
}

@Test func verifierRejectsAChangedColumn() {
    var changed = CobaltSchema.toDo
    changed[0] = CobaltColumn(id: 100, name: "DueDate", type: 0x12, maxSize: 4)
    #expect(CobaltSchemaCheck.verify(changed, kind: .tasks) == [
        .typeDiffers(id: 100, name: "DueDate", expected: 0x0D, actual: 0x12),
        .sizeDiffers(id: 100, name: "DueDate", expected: 2, actual: 4),
    ])
    #expect(CobaltSchemaCheck.verify(Array(CobaltSchema.toDo.dropLast()), kind: .tasks) == [.missing(CobaltSchema.toDo[4])])
    let extra = CobaltColumn(id: 600, name: "Extra", type: 0x10, maxSize: 16)
    #expect(CobaltSchemaCheck.verify(CobaltSchema.toDo + [extra], kind: .tasks) == [.unexpected(extra)])
    // the ROM's own column names do not matter to the check
    #expect(CobaltSchemaCheck.verify([CobaltColumn(id: 100, name: "Text", type: 0x10, maxSize: 0xFFFE)], kind: .memos).isEmpty)
    #expect(CobaltSchemaMismatch.missing(extra).description == "column Extra (600) is missing")
}

// MARK: - The event parser

@Test func sessionEventParsesACobaltRowAsTestCobaltPyEmitsIt() throws {
    let line = """
    {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 2160361473, "attr": 0, "syncStatus": 3, \
    "modified": 1, "deleted": 0, "archived": 0, "present": 11, "err": 0, "categories": [17], \
    "columns": [{"id": 100, "size": 6, "err": 0, "hex": "68656c6c6f00"}]}
    """
    guard case .cobalt(.row(let handle, let table, let row))? = SessionEvent.parse(line) else {
        Issue.record("not a row event")
        return
    }
    #expect(handle == 4)
    #expect(table == "MemoDBSchema")
    #expect(row.rowId == 0x80C4_8001)
    #expect(row.attr == 0)
    #expect(row.syncStatus == 3)
    #expect(row.modified)
    #expect(!row.deleted)
    #expect(!row.archived)
    #expect(row.present == 0x0B)
    #expect(row.categories == [0x11])
    #expect(row.columns == [100: hex("68656c6c6f00")])
    #expect(row.columnErrors.isEmpty)
    #expect(CobaltRecords.memo(row).record.text == "hello")

    // the deleted row of the same stream: no columns, deleted from attr 0x80 / status 4
    let deleted = """
    {"event": "cobaltRow", "handle": 4, "table": "MemoDBSchema", "rowId": 2160361474, "attr": 128, "syncStatus": 4, \
    "modified": 0, "deleted": 1, "archived": 0, "present": 1, "err": 0, "categories": [], "columns": []}
    """
    guard case .cobalt(.row(_, _, let gone))? = SessionEvent.parse(deleted) else {
        Issue.record("not a row event")
        return
    }
    #expect(gone.deleted && !gone.modified)
    #expect(gone.columns.isEmpty)
    #expect(CobaltRecords.recordAttributes(of: gone) == 0x80)

    // the AppInfo row the T|X returned
    let country = """
    {"event": "cobaltRow", "handle": 1, "table": "AddressBookAppInfo", "rowId": 2155601921, "attr": 0, "syncStatus": 3, \
    "modified": 1, "deleted": 0, "archived": 0, "present": 11, "err": 0, "categories": [], \
    "columns": [{"id": 100, "size": 2, "err": 0, "hex": "5355"}]}
    """
    guard case .cobalt(.row(_, _, let appInfo))? = SessionEvent.parse(country) else {
        Issue.record("not a row event")
        return
    }
    #expect(appInfo.rowId == 0x807B_E001)
    #expect(cobaltCountryCode(appInfo[column: 100] ?? Data()) == "US")
}

@Test func sessionEventParsesTheOtherCobaltEvents() {
    #expect(SessionEvent.parse(#"{"event": "cobaltOpened", "handle": 1, "name": "AddressDBS", "creator": "adrs", "mode": 1}"#)
            == .cobalt(.opened(handle: 1, name: "AddressDBS", creator: "adrs", mode: 1)))
    #expect(SessionEvent.parse(#"{"event": "cobaltClosed", "handle": 1, "name": "AddressDBS", "token": "0a0b"}"#)
            == .cobalt(.closed(handle: 1, name: "AddressDBS", token: hex("0a0b"))))
    #expect(SessionEvent.parse(#"{"event": "cobaltClosed", "handle": 2, "name": "MemoDBS"}"#)
            == .cobalt(.closed(handle: 2, name: "MemoDBS", token: nil)))
    #expect(SessionEvent.parse(#"{"event": "cobaltTable", "handle": 1, "name": "AddressBookDBSchema", "columns": 59}"#)
            == .cobalt(.table(handle: 1, name: "AddressBookDBSchema", columns: 59)))
    #expect(SessionEvent.parse(#"{"event": "cobaltTablesDone", "handle": 1, "count": 2}"#) == .cobalt(.tablesDone(handle: 1, count: 2)))
    #expect(SessionEvent.parse(#"{"event": "cobaltColumn", "handle": 1, "table": "AddressBookAppInfo", "id": 100, "name": "Country", "type": 2, "attrib": 0, "maxSize": 2, "err": 0}"#)
            == .cobalt(.column(handle: 1, table: "AddressBookAppInfo", CobaltColumn(id: 100, name: "Country", type: 2, maxSize: 2, attrib: 0))))
    #expect(SessionEvent.parse(#"{"event": "cobaltSchemaDone", "handle": 4, "table": "MemoDBSchema", "count": 1}"#)
            == .cobalt(.schemaDone(handle: 4, table: "MemoDBSchema", count: 1)))
    #expect(SessionEvent.parse(#"{"event": "cobaltCategory", "handle": 1, "id": 16, "name": "Business"}"#)
            == .cobalt(.category(handle: 1, CobaltCategory(id: 0x10, name: "Business"))))
    #expect(SessionEvent.parse(#"{"event": "cobaltCategoriesDone", "handle": 1, "count": 3}"#) == .cobalt(.categoriesDone(handle: 1, count: 3)))
    #expect(SessionEvent.parse(#"{"event": "cobaltSyncState", "handle": 1, "syncable": 1, "format": 65536, "syncId": 602030638, "clock": 1, "rowsPurge": 0, "schemasPurge": 0, "categoryPurge": 0}"#)
            == .cobalt(.syncState(handle: 1, CobaltSyncState(format: 0x0001_0000, syncId: 0x23E2_422E, clock: 1))))
    #expect(SessionEvent.parse(#"{"event": "cobaltSyncState", "handle": 1, "syncable": 0}"#) == .cobalt(.syncState(handle: 1, nil)))
    #expect(SessionEvent.parse(#"{"event": "cobaltRowCount", "handle": 1, "table": "AddressBookAppInfo", "rows": 1}"#)
            == .cobalt(.rowCount(handle: 1, table: "AddressBookAppInfo", rows: 1)))
    #expect(SessionEvent.parse(#"{"event": "cobaltRowsDone", "handle": 4, "table": "MemoDBSchema", "rows": 2, "tables": 1}"#)
            == .cobalt(.rowsDone(handle: 4, table: "MemoDBSchema", rows: 2, tables: 1)))
    #expect(SessionEvent.parse(#"{"event": "cobaltListDone", "count": 18}"#) == .cobalt(.listDone(count: 18)))
    let database = SessionEvent.parse(#"{"event": "cobaltDatabase", "index": 0, "modified": "2026-11-27 01:02:01", "name": "AddressDBS", "type": "DATA", "creator": "adrs", "attr": 4104, "schema": 1, "secure": 0, "misc": 64, "version": 1, "modnum": 308}"#)
    let info = CobaltDatabaseInfo(name: "AddressDBS", type: "DATA", creator: "adrs", attr: 0x1008, version: 1, modificationNumber: 308)
    #expect(database == .cobalt(.database(info)))
    #expect(info.isSchema && !info.isSecure)
    // a cobalt line missing what its event needs is a broken line
    #expect(SessionEvent.parse(#"{"event": "cobaltColumn", "handle": 1, "table": "X", "id": 1}"#) == nil)
    #expect(SessionEvent.parse(#"{"event": "cobaltNothing", "handle": 1}"#) == nil)
}
