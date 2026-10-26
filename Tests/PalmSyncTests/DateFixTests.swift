import Foundation
import Testing
@testable import PalmSync

// DateFix shifts the Palm's dates by (start year − 1904); the bridge shifts
// them back and forth so the engine sees real years.

@Test func offsetDaysAreWholeLeapBlocks() {
    #expect(DateFix.offsetDays(startYear: 1932) == 10_227)   // 28 years = 7 × 1461 days
    #expect(DateFix.offsetDays(startYear: 1904) == 0)
}

@Test func calendarRecordShiftsEveryDate() throws {
    var event = CalendarEvent(date: PalmDate(year: 1998, month: 10, day: 26))
    event.title = "Standup"
    event.repeatRule = .init(type: .weekly, endDate: PalmDate(year: 1999, month: 1, day: 4), frequency: 1)
    event.exceptions = [PalmDate(year: 1998, month: 11, day: 2)]
    let real = try CalendarEvent(data: DateFix.shift(event.encode(), kind: .calendar, years: 28))
    #expect(real.date.year == 2026 && real.repeatRule?.endDate?.year == 2027 && real.exceptions[0].year == 2026)
    // and back, byte for byte
    #expect(DateFix.shift(real.encode(), kind: .calendar, years: -28) == event.encode())
}

@Test func taskAndContactShift() throws {
    var task = PalmTask(title: "Milk", dueDate: PalmDate(year: 1998, month: 10, day: 27), completedDate: PalmDate(year: 1998, month: 10, day: 26))
    task.repeatRule = (PalmDate(year: 1998, month: 10, day: 27), .init(type: .daily, endDate: PalmDate(year: 1998, month: 12, day: 31), frequency: 1))
    let realTask = try PalmTask(data: DateFix.shift(task.encode(), kind: .tasks, years: 28))
    #expect(realTask.dueDate?.year == 2026 && realTask.completedDate?.year == 2026)
    #expect(realTask.repeatRule?.start.year == 2026 && realTask.repeatRule?.rule.endDate?.year == 2026)

    var contact = Contact(fields: [.lastName: "Leto"])
    contact.birthday = .init(date: PalmDate(year: 1962, month: 5, day: 6), reminderAdvance: nil, advanceUnits: 0)
    let anniversary = PalmDate(year: 1990, month: 6, day: 7).packed
    contact.blobs = [PalmBlob(type: "Bd01", data: Data([0, 0, UInt8(anniversary >> 8), UInt8(anniversary & 0xFF), 0]))]
    let real = try Contact(data: DateFix.shift(contact.encode(), kind: .contacts, years: 28))
    #expect(real.birthday?.date.year == 1990)
    #expect(PalmDate(packed: UInt16(real.blobs[0].data[2]) << 8 | UInt16(real.blobs[0].data[3])).year == 2018)
    #expect(DateFix.shift(real.encode(), kind: .contacts, years: -28) == contact.encode())
}

@Test func datesBeforeTheWindowBecomeItsFirstDay() {
    // a 1920 birthday cannot be stored with a 1932 epoch: DateFix sets it to the first year
    #expect(DateFix.shift(PalmDate(year: 1920, month: 3, day: 4), years: -28) == PalmDate(year: 1904, month: 1, day: 1))
}

@Test func wholeDatabaseShiftsOnlyPIMCreators() throws {
    var db = PalmDatabase(name: "TasksDB-PTod", type: "DATA", creator: "PTod", attributes: 0, version: 1, appInfo: TaskAppInfo().encode())
    db.records = [PalmDatabase.Record(category: 0, uniqueID: 1, data: PalmTask(title: "x", dueDate: PalmDate(year: 2026, month: 1, day: 1)).encode())]
    let palm = DateFix.shift(db, years: -28)
    #expect(try PalmTask(data: palm.records[0].data).dueDate?.year == 1998)
    let other = PalmDatabase(name: "locLDefLocationDB", type: "DATA", creator: "locL", attributes: 0, version: 2, appInfo: nil)
    #expect(DateFix.shift(other, years: -28) == other)
    #expect(DateFix.shift(db, years: 0) == db)
}

@Test func clampedBirthdayKeepsTheMirrorsValue() throws {
    // on the Palm (start year 1972) a 1962 birthday became 1972-01-01; read back, the mirror's date stands
    var palm = Contact(fields: [.lastName: "Leto"])
    palm.birthday = .init(date: PalmDate(year: 1972, month: 1, day: 1), reminderAdvance: nil, advanceUnits: 0)
    var base = SyncedContact(palm, category: "Unfiled")
    base.birthday = PalmDate(year: 1962, month: 5, day: 6)
    let fixed = try Contact(data: DateFix.unclamp(palm.encode(), kind: .contacts, startYear: 1972, base: base))
    #expect(fixed.birthday?.date == PalmDate(year: 1962, month: 5, day: 6))
    // a real 1 January 1972 birthday is left alone
    base.birthday = PalmDate(year: 1980, month: 2, day: 3)
    #expect(DateFix.unclamp(palm.encode(), kind: .contacts, startYear: 1972, base: base) == palm.encode())
}
