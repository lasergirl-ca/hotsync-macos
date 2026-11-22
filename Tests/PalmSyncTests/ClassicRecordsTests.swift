import Foundation
import HotSyncCore
import Testing
@testable import PalmSync

/// DatebookDB.pdb, AddressDB.pdb and ToDoDB.pdb are written by
/// Fixtures/generate-classic.c with pilot-link's own packers for the
/// classic PIM databases (Palm OS before 5.2).
private func classicFixture(_ name: String) throws -> PalmDatabase {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "pdb", subdirectory: "Fixtures"))
    return try PalmDatabase(data: Data(contentsOf: url))
}

// MARK: - Datebook

@Test func datebookFixtureRoundTripsThroughTheCalendarCodec() throws {
    let db = try classicFixture("DatebookDB")
    #expect(db.name == "DatebookDB")
    #expect(db.creator == "date")
    #expect(db.records.count == 9)
    for record in db.records {
        let event = try ClassicDatebook.calendarEvent(from: record.data)
        #expect(event.encode() == record.data, "record \(String(record.uniqueID, radix: 16))")
        #expect(event.location == nil)
        #expect(event.blobs.isEmpty)
        #expect(PalmPIMFamily.classic.readsBack(record.data, kind: .calendar))
        #expect(try PalmPIMFamily.classic.garnetRecord(record.data, kind: .calendar) == record.data)
    }
    let gym = try CalendarEvent(data: db.records[4].data)
    #expect(gym.title == "Gym")
    #expect(gym.repeatRule?.type == .weekly)
    #expect(gym.repeatRule?.weekdays == [.monday, .wednesday, .friday])
    #expect(gym.repeatRule?.endDate == PalmDate(year: 2027, month: 3, day: 31))
    #expect(gym.exceptions == [PalmDate(year: 2026, month: 10, day: 23), PalmDate(year: 2026, month: 10, day: 28)])
    let birthday = try CalendarEvent(data: db.records[7].data)
    #expect(birthday.title == "Momâs birthday")
    #expect(birthday.note == "Café")
    #expect(birthday.time == nil)
    #expect(birthday.alarm == .init(advance: 1, unit: .days))
    #expect(birthday.repeatRule?.type == .yearly)
    #expect(db.records[8].isDeleted)

    let info = try ClassicDatebookAppInfo(data: try #require(db.appInfo))
    #expect(info.categories.named.map(\.name) == ["Unfiled", "Work", "Family", "G Work"])
    #expect(info.startOfWeek == 0)
    #expect(info.encode() == db.appInfo)
    #expect(PalmPIMFamily.classic.categories(ofAppInfo: db.appInfo!, kind: .calendar)?.names.prefix(2) == ["Unfiled", "Work"])
}

@Test func aDatebookNeverGetsALocationOrABlob() throws {
    var event = CalendarEvent(date: PalmDate(year: 2026, month: 11, day: 21), title: "Lunch", location: "Downtown")
    event.timezone = PalmTimezone(offsetMinutes: -480, name: "Vancouver")
    let limited = ClassicDatebook.limit(event)
    #expect(limited.location == nil)
    #expect(limited.blobs.isEmpty)
    #expect(limited.title == "Lunch")
    // the Garnet bytes with a location are refused as Datebook bytes
    #expect(throws: PalmFormatError.self) { try ClassicDatebook.calendarEvent(from: event.encode()) }
    let device = try PalmPIMFamily.classic.deviceRecord(event.encode(), kind: .calendar)
    #expect(device == limited.encode())
    #expect(try PalmPIMFamily.classic.garnetRecord(device, kind: .calendar) == device)
}

// MARK: - Address

@Test func addressFixtureRoundTrips() throws {
    let db = try classicFixture("AddressDB")
    #expect(db.creator == "addr")
    #expect(db.records.count == 4)
    for record in db.records {
        let address = try ClassicAddress(data: record.data)
        #expect(address.encode() == record.data, "record \(String(record.uniqueID, radix: 16))")
        #expect(PalmPIMFamily.classic.readsBack(record.data, kind: .contacts))
    }
    let zoe = try ClassicAddress(data: db.records[0].data)
    #expect(zoe[.lastName] == "Leto")
    #expect(zoe[.firstName] == "Zoë")
    #expect(zoe[.company] == "Packetloq")
    #expect(zoe[.phone3] == "zoe@example.com")
    #expect(zoe.phoneLabels == [0, 1, 4, 7, 2])
    #expect(zoe.showPhone == 3)
    #expect(zoe[.zip] == "V6B 1A1")
    #expect(zoe[.custom4] == "c4")
    #expect(zoe[.note] == "Likes Palms")
    let dentist = try ClassicAddress(data: db.records[1].data)
    #expect(dentist[.lastName] == nil)
    #expect(dentist[.company] == "Dentist")
    #expect(dentist[.phone1] == "+1 604 555 0200")
    #expect(db.records[2].isSecret)
    #expect(db.records[3].isDeleted)

    let info = try ClassicAddressAppInfo(data: try #require(db.appInfo))
    #expect(info.categories.named.map(\.name) == ["Unfiled", "Friends", "Work", "Family"])
    #expect(info.labels[0] == "Last name")
    #expect(info.labels[21] == "Mobile")
    #expect(info.phoneLabels == ["Work", "Home", "Fax", "Other", "E-mail", "Main", "Pager", "Mobile"])
    #expect(info.country == 4)
    #expect(!info.sortByCompany)
    #expect(info.encode() == db.appInfo)
}

@Test func anAddressBecomesAContactAndBack() throws {
    let db = try classicFixture("AddressDB")
    let bytes = db.records[0].data
    let contact = try ClassicAddress(data: bytes).contact
    #expect(contact[.lastName] == "Leto")
    #expect(contact[.phone3] == "zoe@example.com")
    #expect(contact.phoneLabel(2) == 4)
    #expect(contact.phoneLabel(3) == 7)
    #expect(contact.showPhone == 3)
    #expect(contact[.address1] == "123 Main St")
    #expect(contact[.country1] == "Canada")
    #expect(contact[.title] == "Engineer")
    #expect(contact[.custom4] == "c4")
    #expect(contact[.note] == "Likes Palms")
    #expect(contact.addressLabel(0) == 0)
    #expect(contact[.phone6] == nil)
    #expect(contact.birthday == nil)
    // the Contacts record goes back as the very same Address bytes
    #expect(ClassicAddress(contact).encode() == bytes)
    #expect(try PalmPIMFamily.classic.deviceRecord(contact.encode(), kind: .contacts) == bytes)
    #expect(try PalmPIMFamily.classic.garnetRecord(bytes, kind: .contacts) == contact.encode())

    let synced = SyncedContact(contact, category: "Friends")
    #expect(synced.phones.count == 5)
    #expect(synced.phones[2].isEmail)
    #expect(synced.addresses.count == 1)
    #expect(synced.addresses[0].label == 0)
    #expect(synced.title == "Zoë Leto")
}

@Test func theAddressLimitDropsWhatAnAddressCannotHold() throws {
    var full = Contact(fields: [.lastName: "Doe", .firstName: "Jane", .phone1: "1", .phone2: "2", .phone3: "3", .phone4: "4",
                                .phone5: "5", .phone6: "6", .phone7: "7", .im1: "jane", .website: "https://example.com",
                                .address1: "A", .address2: "B", .custom5: "x"],
                       birthday: .init(date: PalmDate(year: 1980, month: 5, day: 5)))
    full.setAddressLabel(0, 1)   // work
    full.setPhoneLabel(6, 7)
    let limited = ClassicAddress.limit(full)
    #expect(limited[.phone5] == "5")
    #expect(limited[.phone6] == nil)
    #expect(limited[.phone7] == nil)
    #expect(limited[.im1] == nil)
    #expect(limited[.website] == nil)
    #expect(limited[.address1] == "A")
    #expect(limited[.address2] == nil)
    #expect(limited[.custom5] == nil)
    #expect(limited.birthday == nil)
    #expect(limited.addressLabel(0) == 0)
    // the limit is a fixed point, and what the Palm hands back is the limit
    #expect(ClassicAddress.limit(limited) == limited)
    let onPalm = ClassicAddress(full).encode()
    #expect(try ClassicAddress(data: onPalm).contact == limited)
    #expect(PalmPIMFamily.classic.limit(full) == limited)
    #expect(PalmPIMFamily.garnet.limit(full) == full)

    // the Mac-side item limited the same way the record is
    let item = SyncedContact(full, category: "Unfiled")
    let contactLimit = try #require(PalmPIMFamily.classic.contactLimit)
    #expect(contactLimit(item) == SyncedContact(limited, category: "Unfiled"))
    #expect(PalmPIMFamily.garnet.contactLimit == nil)
}

// MARK: - To Do

@Test func toDoFixtureRoundTrips() throws {
    let db = try classicFixture("ToDoDB")
    #expect(db.creator == "todo")
    #expect(db.records.count == 5)
    for record in db.records {
        let todo = try ClassicToDo(data: record.data)
        #expect(todo.encode() == record.data, "record \(String(record.uniqueID, radix: 16))")
        #expect(PalmPIMFamily.classic.readsBack(record.data, kind: .tasks))
    }
    let milk = try ClassicToDo(data: db.records[0].data)
    #expect(milk.title == "Buy milk")
    #expect(milk.note == "2%")
    #expect(milk.priority == 2)
    #expect(milk.dueDate == PalmDate(year: 2026, month: 10, day: 25))
    #expect(!milk.completed)
    let mom = try ClassicToDo(data: db.records[1].data)
    #expect(mom.dueDate == nil)
    #expect(mom.priority == 5)
    #expect(mom.completed)
    #expect(mom.note == "")
    let resume = try ClassicToDo(data: db.records[3].data)
    #expect(resume.title == "Résumé")

    let info = try ClassicToDoAppInfo(data: try #require(db.appInfo))
    #expect(info.categories.named.map(\.name) == ["Unfiled", "Personal", "Groceries", "Amazon"])
    #expect(info.sortByPriority)
    #expect(info.encode() == db.appInfo)
}

@Test func aToDoBecomesATaskWithAFixedCompletionDate() throws {
    let db = try classicFixture("ToDoDB")
    let milk = try ClassicToDo(data: db.records[0].data).palmTask
    #expect(milk.completedDate == nil)
    #expect(milk.alarm == nil)
    #expect(milk.repeatRule == nil)
    let mom = try ClassicToDo(data: db.records[1].data).palmTask
    #expect(mom.completedDate == ClassicToDo.completedWithoutDate)
    let insurance = try ClassicToDo(data: db.records[2].data).palmTask
    #expect(insurance.completedDate == PalmDate(year: 2026, month: 9, day: 1))   // its due day
    for record in db.records {
        let task = try ClassicToDo(data: record.data).palmTask
        #expect(ClassicToDo(task).encode() == record.data)
        #expect(try PalmPIMFamily.classic.deviceRecord(task.encode(), kind: .tasks) == record.data)
        #expect(try PalmPIMFamily.classic.garnetRecord(record.data, kind: .tasks) == task.encode())
    }

    // a Mac task completed on some day, with an alarm and a repeat: the
    // limit is what the Palm hands back
    var full = PalmTask(title: "Taxes", note: "", priority: 2, dueDate: PalmDate(year: 2027, month: 4, day: 30),
                        completedDate: PalmDate(year: 2027, month: 4, day: 12),
                        alarm: .init(time: PalmTime(hour: 9, minute: 0), daysEarlier: 1))
    full.repeatRule = (PalmDate(year: 2027, month: 4, day: 30), .init(type: .yearly))
    let limited = ClassicToDo.limit(full)
    #expect(limited.completedDate == PalmDate(year: 2027, month: 4, day: 30))
    #expect(limited.alarm == nil)
    #expect(limited.repeatRule == nil)
    #expect(ClassicToDo.limit(limited) == limited)
    #expect(try ClassicToDo(data: ClassicToDo(full).encode()).palmTask == limited)
    let item = SyncedTask(full, category: "Unfiled")
    let taskLimit = try #require(PalmPIMFamily.classic.taskLimit)
    #expect(taskLimit(item) == SyncedTask(limited, category: "Unfiled"))
    // priorities outside 1-5 are pulled in
    #expect(ClassicToDo(PalmTask(title: "x", priority: 0)).priority == 1)
    #expect(ClassicToDo(PalmTask(title: "x", priority: 9)).priority == 5)
}

// MARK: - The family

@Test func thePalmOSVersionPicksTheFamily() {
    #expect(PalmOSVersion(rom: 0x0410_3000).pimFamily == .classic)   // m515, Palm OS 4.1
    #expect(PalmOSVersion(rom: 0x0350_3000).pimFamily == .classic)   // Palm V, 3.5
    #expect(PalmOSVersion(rom: 0x0500_3000).pimFamily == .classic)   // Tungsten T, 5.0
    #expect(PalmOSVersion(rom: 0x0521_3000).pimFamily == .garnet)    // Tungsten T3, 5.2.1
    #expect(PalmOSVersion(rom: 0x0549_3000).pimFamily == .garnet)    // T|X, 5.4.9
    #expect(PalmPIMFamily.classic.databaseName(.calendar) == "DatebookDB")
    #expect(PalmPIMFamily.classic.databaseName(.contacts) == "AddressDB")
    #expect(PalmPIMFamily.classic.databaseName(.tasks) == "ToDoDB")
    #expect(PalmPIMFamily.garnet.databaseName(.contacts) == "ContactsDB-PAdd")
    #expect(PalmPIMFamily.kind(ofDatabase: "ToDoDB") == .tasks)
    #expect(PalmPIMFamily.kind(ofDatabase: "CalendarDB-PDat") == .calendar)
    #expect(PalmPIMFamily.family(ofDatabase: "AddressDB") == .classic)
    #expect(PalmPIMFamily.family(ofDatabase: "TasksDB-PTod") == .garnet)
    #expect(PalmPIMFamily.kind(ofDatabase: "MemoDB") == nil)
}

@Test func aClassicPalmSyncsThroughTheGarnetEngine() throws {
    // the Palm's AddressDB as the session reads it, plus a Mac contact the
    // Address cannot hold in full: the plan installs an AddressDB again
    let db = try classicFixture("AddressDB")
    let family = PalmPIMFamily.classic
    let palm = db.records.map { PalmRecordIn(id: $0.uniqueID, attributes: $0.attributes, category: $0.category, data: $0.data) }
    let snapshot = PalmSnapshot.all(family.garnetRecords(palm, kind: .contacts))
    let categories = try #require(family.categories(ofAppInfo: db.appInfo!, kind: .contacts))

    var macRecord = Contact(fields: [.lastName: "Mac", .firstName: "Only", .phone1: "+1 604 555 0300", .im1: "maconly",
                                     .website: "https://example.com"])
    macRecord.setPhoneLabel(0, 7)
    let mac = family.limited([MacSyncItem(key: MacKey(seriesID: "mac-1"), item: SyncedContact(macRecord, category: "Work"),
                                          palmRecord: macRecord.encode())])
    #expect(mac[0].item.website == nil)
    #expect(mac[0].item.instantMessages.isEmpty)

    let engine = SyncEngine<SyncedContact>(conflictPolicy: .macWins)
    let plan = try engine.plan(palm: snapshot, palmCategories: categories.names, mac: mac, mirror: SyncMirror<SyncedContact>(pcID: 1))
    // three live Palm records reach the Mac, the Mac's one goes to the Palm
    #expect(plan.macCreates.count == 3)
    #expect(plan.palmWrites.count == 1)

    let garnetAppInfo = ContactAppInfo(categories: categories, labels: Array(repeating: "", count: ContactAppInfo.labelCountV11))
    let (garnet, _, newCategories) = plan.palmDatabase(appInfo: garnetAppInfo)
    let install = family.deviceDatabase(garnet, kind: .contacts,
                                        appInfo: family.classicAppInfo(kind: .contacts, existing: db.appInfo, categories: newCategories))
    #expect(install.name == "AddressDB")
    #expect(install.creator == "addr")
    #expect(install.records.count == 4)
    for record in install.records {
        #expect(family.readsBack(record.data, kind: .contacts), "record \(String(record.uniqueID, radix: 16))")
    }
    let info = try ClassicAddressAppInfo(data: try #require(install.appInfo))
    #expect(info.labels == ClassicAddressAppInfo.defaultLabels)   // the Palm's own labels survive
    #expect(info.country == 4)
    #expect(info.categories.named.map(\.name).contains("Work"))
    let macOnPalm = try #require(install.records.first { (try? ClassicAddress(data: $0.data))?[.lastName] == "Mac" })
    let address = try ClassicAddress(data: macOnPalm.data)
    #expect(address[.phone1] == "+1 604 555 0300")
    #expect(address.phoneLabels[0] == 7)
    // the Palm's untouched records come back byte for byte
    let zoe = try #require(install.records.first { (try? ClassicAddress(data: $0.data))?[.lastName] == "Leto" })
    #expect(zoe.data == db.records[0].data)
}
