import Foundation
import Testing
@testable import PalmSync

// The window and home zone of the builder tests, Vancouver after Nov 1, 2026.
private let vancouver = TimeZone(identifier: "America/Vancouver")!
private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = vancouver
    return c
}()
private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
private let personal = CalendarBuilder.MacCalendar(id: "ical-personal", title: "Personal")
private let family = CalendarBuilder.MacCalendar(id: "ical-family", title: "Family")
private let builder = CalendarBuilder(options: .init(homeZone: vancouver, windowStart: at(2026, 7, 21), windowEnd: at(2027, 10, 19),
                                                     calendars: [personal, family]))
private let engine = CalendarSyncEngine(windowStart: PalmDate(year: 2026, month: 7, day: 21),
                                        windowEnd: PalmDate(year: 2027, month: 10, day: 19))
private let palmCategories = ["Unfiled", "Personal", "Family"]

private func macEvent(_ title: String, _ start: Date, minutes: Int = 60, calendar: String = "ical-personal",
                      series: String? = nil, notes: String? = nil) -> MacEvent {
    MacEvent(seriesID: series ?? title, calendarID: calendar, title: title, notes: notes,
             start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
}

private func items(_ events: [MacEvent]) -> [CalendarBuilder.MacItem] {
    builder.items(events).items
}

private func palmRecord(id: UInt32, _ title: String, _ date: PalmDate, start: PalmTime? = PalmTime(hour: 9, minute: 0),
                        note: String? = nil, category: Int = 1, attributes: UInt8 = 0,
                        blobs: [PalmBlob] = []) -> PalmRecordIn {
    let event = CalendarEvent(date: date, time: start.map { .init(start: $0, end: PalmTime(hour: $0.hour + 1, minute: $0.minute)) },
                              title: title, note: note, blobs: blobs)
    return PalmRecordIn(id: id, attributes: attributes, category: category, data: event.encode())
}

private func event(_ data: Data) -> CalendarEvent { try! CalendarEvent(data: data) }

/// A mirror as a first sync leaves it: `standup` on both sides, agreed.
private let standupStart = at(2026, 10, 20, 9, 0)
private let standupDate = PalmDate(year: 2026, month: 10, day: 20)
private func syncedMirror() -> SyncMirror {
    let plan = try! engine.plan(palm: .all([]), palmCategories: palmCategories,
                                mac: items([macEvent("Standup", standupStart)]), mirror: SyncMirror(pcID: 7))
    return plan.mirror(after: SyncMirror(pcID: 7), palmIDs: [0: 0x1001], macKeys: [:], at: at(2026, 10, 19, 12, 0))
}

// MARK: - First sync

@Test func firstSyncCopiesEachSideToTheOther() throws {
    let mac = items([macEvent("Standup", standupStart), macEvent("Dinner", at(2026, 10, 21, 19, 0), calendar: "ical-family")])
    let palm = PalmSnapshot.all([palmRecord(id: 0x2001, "Dentist", PalmDate(year: 2026, month: 10, day: 22), category: 1)])
    let plan = try engine.plan(palm: palm, palmCategories: palmCategories, mac: mac, mirror: SyncMirror(pcID: 7))

    #expect(plan.palmWrites.count == 2 && plan.palmWrites.allSatisfy { $0.id == nil })
    #expect(plan.palmWrites.map(\.category) == [1, 2])
    #expect(event(plan.palmWrites[1].record).title == "Dinner")
    #expect(plan.macCreates.count == 1 && plan.macCreates[0].event.title == "Dentist" && plan.macCreates[0].event.category == "Personal")
    #expect(plan.palmDeletes.isEmpty && plan.macUpdates.isEmpty && plan.macDeletes.isEmpty && plan.conflicts.isEmpty)
    #expect(plan.entries.count == 3)

    // the IDs the Palm and the Mac assign complete the mirror; each write
    // says which entry it belongs to
    let dentistKey = MacKey(seriesID: "created-on-mac")
    let standup = plan.palmWrites[0].entry, dinner = plan.palmWrites[1].entry, dentist = plan.macCreates[0].entry
    let mirror = plan.mirror(after: SyncMirror(pcID: 7), palmIDs: [standup: 0x1001, dinner: 0x1002], macKeys: [dentist: dentistKey])
    #expect(mirror.entries.count == 3)
    #expect(Set(mirror.entries.map(\.palmID)) == [0x1001, 0x1002, 0x2001])
    #expect(mirror.entries.first { $0.palmID == 0x2001 }?.mac == dentistKey)
    #expect(mirror.entries.first { $0.palmID == 0x1002 }?.base.category == "Family")
    #expect(mirror.lastSync != nil)

    // an entry whose ID never came back is not remembered
    let partial = plan.mirror(after: SyncMirror(pcID: 7), palmIDs: [standup: 0x1001], macKeys: [:])
    #expect(partial.entries.count == 1 && partial.entries[0].palmID == 0x1001)
}

@Test func slowSyncPairsTheSameEventOnBothSides() throws {
    let mac = items([macEvent("Standup", standupStart, notes: "bring coffee")])
    let palm = PalmSnapshot.all([palmRecord(id: 0x1001, "Standup", standupDate)])
    let plan = try engine.plan(palm: palm, palmCategories: palmCategories, mac: mac, mirror: SyncMirror(pcID: 7))

    #expect(plan.macCreates.isEmpty)
    // paired, and the Mac's note (the only difference) goes to the Palm
    #expect(plan.palmWrites.count == 1 && plan.palmWrites[0].id == 0x1001)
    #expect(event(plan.palmWrites[0].record).note == "bring coffee")
    #expect(plan.conflicts.isEmpty)
    #expect(plan.log.contains { $0.contains("paired") })
}

@Test func mirrorSavesAndLoads() throws {
    let mirror = syncedMirror()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("palmsync-test-\(UUID().uuidString).json")
    try mirror.save(to: url)
    #expect(try SyncMirror.load(from: url) == mirror)
    try FileManager.default.removeItem(at: url)
}

// MARK: - Fast sync

@Test func nothingChangedIsAnEmptyPlan() throws {
    let plan = try engine.plan(palm: .modified([]), palmCategories: palmCategories,
                               mac: items([macEvent("Standup", standupStart)]), mirror: syncedMirror())
    #expect(plan.isEmpty)
    #expect(plan.entries.count == 1 && plan.entries[0].palmID == 0x1001)
}

@Test func fastSyncNeedsAMirror() {
    #expect(throws: SyncError.fastSyncWithoutMirror) {
        try engine.plan(palm: .modified([]), palmCategories: palmCategories, mac: [], mirror: SyncMirror(pcID: 7))
    }
}

@Test func macEditGoesToThePalm() throws {
    var moved = macEvent("Standup", at(2026, 10, 20, 9, 30))
    moved.location = "Room 4"
    let plan = try engine.plan(palm: .modified([]), palmCategories: palmCategories, mac: items([moved]), mirror: syncedMirror())
    #expect(plan.palmWrites.count == 1 && plan.palmWrites[0].id == 0x1001)
    let record = event(plan.palmWrites[0].record)
    #expect(record.time?.start == PalmTime(hour: 9, minute: 30) && record.location == "Room 4")
    #expect(plan.macUpdates.isEmpty && plan.conflicts.isEmpty)
    #expect(plan.entries[0].event.location == "Room 4")
}

@Test func palmEditGoesToTheMac() throws {
    let edited = palmRecord(id: 0x1001, "Standup (moved)", standupDate, start: PalmTime(hour: 10, minute: 0), attributes: 0x40)
    let plan = try engine.plan(palm: .modified([edited]), palmCategories: palmCategories,
                               mac: items([macEvent("Standup", standupStart)]), mirror: syncedMirror())
    #expect(plan.palmWrites.isEmpty)
    #expect(plan.macUpdates.count == 1)
    #expect(plan.macUpdates[0].key == MacKey(seriesID: "Standup"))
    #expect(plan.macUpdates[0].event.title == "Standup (moved)" && plan.macUpdates[0].event.time?.start == PalmTime(hour: 10, minute: 0))
    #expect(plan.entries[0].palmRecord == edited.data)
}

@Test func differentFieldsMergeBothWays() throws {
    // the Palm changed the title, the Mac the time
    let palmEdit = palmRecord(id: 0x1001, "Standup!", standupDate, attributes: 0x40)
    let macEdit = macEvent("Standup", at(2026, 10, 20, 9, 15))
    let plan = try engine.plan(palm: .modified([palmEdit]), palmCategories: palmCategories, mac: items([macEdit]), mirror: syncedMirror())
    #expect(plan.conflicts.isEmpty)
    let toPalm = event(plan.palmWrites[0].record)
    #expect(toPalm.title == "Standup!" && toPalm.time?.start == PalmTime(hour: 9, minute: 15))
    #expect(plan.macUpdates[0].event.title == "Standup!" && plan.macUpdates[0].event.time?.start == PalmTime(hour: 9, minute: 15))
}

@Test func sameFieldConflictGoesToTheMacAndTheLog() throws {
    let palmEdit = palmRecord(id: 0x1001, "Standup (Palm)", standupDate, attributes: 0x40)
    let plan = try engine.plan(palm: .modified([palmEdit]), palmCategories: palmCategories,
                               mac: items([macEvent("Standup (Mac)", standupStart, series: "Standup")]), mirror: syncedMirror())
    #expect(plan.conflicts.count == 1)
    #expect(plan.conflicts[0].field == .title && plan.conflicts[0].palmValue == "Standup (Palm)" && plan.conflicts[0].macValue == "Standup (Mac)")
    #expect(event(plan.palmWrites[0].record).title == "Standup (Mac)")
    #expect(plan.macUpdates.isEmpty)
    #expect(plan.entries[0].event.title == "Standup (Mac)")
}

@Test func palmBlobsSurviveAMacEdit() throws {
    // first sync with a Palm record that carries a blob
    let blob = PalmBlob(type: "Bd01", data: Data([1, 2, 3]))
    let palm = palmRecord(id: 0x3001, "Call", PalmDate(year: 2026, month: 11, day: 5), blobs: [blob])
    var first = try engine.plan(palm: .all([palm]), palmCategories: palmCategories, mac: [], mirror: SyncMirror(pcID: 7))
    first.log = []
    let mirror = first.mirror(after: SyncMirror(pcID: 7), palmIDs: [:], macKeys: [0: MacKey(seriesID: "call")])

    // the Mac renames it
    let plan = try engine.plan(palm: .modified([]), palmCategories: palmCategories,
                               mac: items([macEvent("Call (renamed)", at(2026, 11, 5, 9, 0), series: "call")]), mirror: mirror)
    let written = event(plan.palmWrites[0].record)
    #expect(written.title == "Call (renamed)")
    #expect(written.blobs == [blob])
}

// MARK: - Deletes

@Test func deleteOnOneSideUnchangedOnTheOther() throws {
    let deletedOnPalm = PalmRecordIn(id: 0x1001, attributes: 0xC0, category: 1, data: Data())
    let a = try engine.plan(palm: .modified([deletedOnPalm]), palmCategories: palmCategories,
                            mac: items([macEvent("Standup", standupStart)]), mirror: syncedMirror())
    #expect(a.macDeletes == [MacKey(seriesID: "Standup")] && a.palmDeletes.isEmpty && a.entries.isEmpty)

    let b = try engine.plan(palm: .modified([]), palmCategories: palmCategories, mac: [], mirror: syncedMirror())
    #expect(b.palmDeletes == [0x1001] && b.macDeletes.isEmpty && b.entries.isEmpty)

    // a slow sync lists everything: a record that is not listed is gone
    let c = try engine.plan(palm: .all([]), palmCategories: palmCategories,
                            mac: items([macEvent("Standup", standupStart)]), mirror: syncedMirror())
    #expect(c.macDeletes == [MacKey(seriesID: "Standup")])
}

@Test func editWinsOverDelete() throws {
    let deletedOnPalm = PalmRecordIn(id: 0x1001, attributes: 0xC0, category: 1, data: Data())
    let a = try engine.plan(palm: .modified([deletedOnPalm]), palmCategories: palmCategories,
                            mac: items([macEvent("Standup", at(2026, 10, 20, 11, 0))]), mirror: syncedMirror())
    #expect(a.macDeletes.isEmpty)
    #expect(a.palmWrites.count == 1 && a.palmWrites[0].id == nil)   // written as a new record
    #expect(event(a.palmWrites[0].record).time?.start == PalmTime(hour: 11, minute: 0))

    let editedOnPalm = palmRecord(id: 0x1001, "Standup", standupDate, note: "keep me", attributes: 0x40)
    let b = try engine.plan(palm: .modified([editedOnPalm]), palmCategories: palmCategories, mac: [], mirror: syncedMirror())
    #expect(b.palmDeletes.isEmpty)
    #expect(b.macCreates.count == 1 && b.macCreates[0].event.note == "keep me")
    #expect(b.entries[0].palmID == 0x1001 && b.entries[0].mac == nil)
}

@Test func archivedOnThePalmStaysOnTheMac() throws {
    let archived = PalmRecordIn(id: 0x1001, attributes: 0x88, category: 1, data: Data())
    let plan = try engine.plan(palm: .modified([archived]), palmCategories: palmCategories,
                               mac: items([macEvent("Standup", standupStart)]), mirror: syncedMirror())
    #expect(plan.isEmpty)
    #expect(plan.entries.isEmpty)
    #expect(plan.log.contains { $0.contains("archived") })
}

@Test func leavingTheWindowRemovesFromThePalmOnly() throws {
    var old = syncedMirror()
    old.entries[0].base.date = PalmDate(year: 2026, month: 3, day: 1)
    let plan = try engine.plan(palm: .modified([]), palmCategories: palmCategories, mac: [], mirror: old)
    #expect(plan.palmDeletes == [0x1001])
    #expect(plan.macDeletes.isEmpty && plan.entries.isEmpty)
}

// MARK: - Ownership and categories

@Test func macOwnedItemsTakeNoPalmEdits() throws {
    var owned = syncedMirror()
    owned.entries[0].macOwned = true
    let palmEdit = palmRecord(id: 0x1001, "Standup (Palm)", standupDate, attributes: 0x40)
    let plan = try engine.plan(palm: .modified([palmEdit]), palmCategories: palmCategories,
                               mac: items([macEvent("Standup", standupStart)]), mirror: owned)
    #expect(plan.macUpdates.isEmpty)
    #expect(plan.palmWrites.count == 1 && event(plan.palmWrites[0].record).title == "Standup")
    #expect(plan.log.contains { $0.contains("undone") })
    #expect(plan.entries[0].macOwned)
}

@Test func expandedOccurrencesAreMacOwned() {
    let counted = MacRecurrence(frequency: .daily, end: .count(2))
    let days = (0..<2).map { macEvent("Pills", at(2026, 10, 20, 8, 0).addingTimeInterval(Double($0) * 86400), series: "pills") }
        .map { var e = $0; e.recurrence = counted; e.occurrenceDate = e.start; return e }
    let built = items(days)
    #expect(built.count == 2 && built.allSatisfy(\.macOwned))
    #expect(built.map(\.key.occurrence) == [at(2026, 10, 20, 8, 0), at(2026, 10, 21, 8, 0)])
}

@Test func categoryMissingOnThePalmIsReported() throws {
    let plan = try engine.plan(palm: .all([]), palmCategories: ["Unfiled", "Personal"],
                               mac: items([macEvent("Dinner", at(2026, 10, 21, 19, 0), calendar: "ical-family")]),
                               mirror: SyncMirror(pcID: 7))
    #expect(plan.palmWrites[0].category == 0)
    #expect(plan.missingCategories == ["Family"])
}

// MARK: - Installing the Palm side whole

@Test func planBecomesAWholePalmDatabase() throws {
    let mac = items([macEvent("Standup", standupStart), macEvent("Dinner", at(2026, 10, 21, 19, 0), calendar: "ical-family")])
    let palm = PalmSnapshot.all([palmRecord(id: 0x2001, "Dentist", PalmDate(year: 2026, month: 10, day: 22), category: 1)])
    let plan = try engine.plan(palm: palm, palmCategories: palmCategories, mac: mac, mirror: SyncMirror(pcID: 7))

    let (db, palmIDs, categories) = plan.palmDatabase(categories: CategoryAppInfo(names: palmCategories))
    #expect(db.records.count == 3 && db.name == "CalendarDB-PDat" && db.version == 1)
    // the Palm's own record keeps its ID, the Mac's two get new ones above it
    #expect(db.records.map(\.uniqueID).sorted() == [0x2001, 0x2002, 0x2003])
    #expect(palmIDs.count == 2 && palmIDs.values.allSatisfy { $0 > 0x2001 })
    #expect(db.uniqueIDSeed == 0x2004)
    // sorted by date: Standup (20th), Dinner (21st), Dentist (22nd)
    #expect(try db.records.map { try CalendarEvent(data: $0.data).title } == ["Standup", "Dinner", "Dentist"])
    #expect(db.records.map(\.category) == [1, 2, 1])
    #expect(categories.names.prefix(3) == ["Unfiled", "Personal", "Family"])

    // the mirror built from those IDs is complete
    let mirror = plan.mirror(after: SyncMirror(pcID: 7), palmIDs: palmIDs, macKeys: [plan.macCreates[0].entry: MacKey(seriesID: "new")])
    #expect(mirror.entries.count == 3)
    #expect(try PalmDatabase(data: db.encode()) == db)
}

@Test func unknownCategoryGetsAFreeSlot() throws {
    let mac = items([macEvent("Dinner", at(2026, 10, 21, 19, 0), calendar: "ical-family")])
    let plan = try engine.plan(palm: .all([]), palmCategories: ["Unfiled", "Personal"], mac: mac, mirror: SyncMirror(pcID: 7))
    let (db, _, categories) = plan.palmDatabase(categories: CategoryAppInfo(names: ["Unfiled", "Personal"]))
    #expect(categories.names[2] == "Family")
    #expect(db.records[0].category == 2)
}

// MARK: - Conflict policy

@Test func palmWinsPolicyKeepsThePalmsValue() throws {
    var palmFirst = engine
    palmFirst.conflictPolicy = .palmWins
    let palmEdit = palmRecord(id: 0x1001, "Standup (Palm)", standupDate, attributes: 0x40)
    let plan = try palmFirst.plan(palm: .modified([palmEdit]), palmCategories: palmCategories,
                                  mac: items([macEvent("Standup (Mac)", standupStart, series: "Standup")]), mirror: syncedMirror())
    #expect(plan.conflicts.count == 1)
    #expect(plan.palmWrites.isEmpty)   // the Palm already has the winning value
    #expect(plan.macUpdates.count == 1 && plan.macUpdates[0].event.title == "Standup (Palm)")
    #expect(plan.entries[0].event.title == "Standup (Palm)")
}

@Test func keepBothPolicyDuplicatesThePalmsVersion() throws {
    var both = engine
    both.conflictPolicy = .keepBoth
    let palmEdit = palmRecord(id: 0x1001, "Standup (Palm)", standupDate, attributes: 0x40)
    let plan = try both.plan(palm: .modified([palmEdit]), palmCategories: palmCategories,
                             mac: items([macEvent("Standup (Mac)", standupStart, series: "Standup")]), mirror: syncedMirror())
    #expect(plan.conflicts.count == 1)
    // the paired item takes the Mac's value …
    #expect(plan.entries.contains { $0.palmID == 0x1001 && $0.event.title == "Standup (Mac)" })
    // … and the Palm's version becomes a new item on both sides
    let copy = try #require(plan.entries.firstIndex { $0.palmID == nil && $0.mac == nil })
    #expect(plan.entries[copy].event.title == "Standup (Palm)")
    #expect(plan.palmWrites.contains { $0.entry == copy && $0.id == nil })
    #expect(plan.macCreates.contains { $0.entry == copy })
    #expect(plan.log.contains { $0.contains("kept as a second item") })
    // both IDs filled in, the mirror knows the copy
    let mirror = plan.mirror(after: syncedMirror(), palmIDs: [copy: 0x1002], macKeys: [copy: MacKey(seriesID: "copy")])
    #expect(mirror.entries.count == 2)
}
