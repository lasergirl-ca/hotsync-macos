import Foundation
import HotSyncCore

/// Which PIM applications a Palm runs: the Garnet ones of Palm OS 5.2 and
/// later (Calendar, Contacts, Tasks, Memos: CalendarDB-PDat, ContactsDB-PAdd,
/// TasksDB-PTod, MemosDB-PMem) or the classic ones before (Datebook,
/// Address, To Do, Memo Pad: DatebookDB, AddressDB, ToDoDB, MemoDB).
///
/// The sync engine, the mirrors, the builders and the Mac writers work on
/// the Garnet records throughout. For a classic Palm the records are
/// converted at the edge: what is read from the Palm becomes a Garnet
/// record, what goes onto the Palm becomes a classic one, and the Mac's
/// items are limited to what a classic record can hold before they are
/// compared, so a round trip through the Palm changes nothing.
///
/// Palm OS Cobalt (6.x) keeps the same four applications' data in schema
/// databases (AddressDBS, DateBookDBS, ToDoDBS, MemoDBS): tables of typed
/// columns reached through Cobalt-only DLP commands, not byte records. The
/// rows become Garnet records at the edge too (`CobaltRecords`), so once
/// read, a Cobalt Palm looks like a Garnet one to the engine; the byte
/// functions below treat it as Garnet. Writing rows is not implemented yet.
public enum PalmPIMFamily: String, Codable, Sendable, Equatable {
    case garnet
    case classic
    case cobalt

    /// Schema databases (Cobalt): read with the `cobalt...` commands and
    /// `CobaltDatabaseReader`, not `opendb`/`readall`.
    public var isSchema: Bool { self == .cobalt }

    /// The families whose databases are known by name.
    public static let all: [PalmPIMFamily] = [.garnet, .classic, .cobalt]

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case calendar, contacts, tasks, memos
    }

    // MARK: Databases

    public func databaseName(_ kind: Kind) -> String {
        switch (self, kind) {
        case (.garnet, .calendar): return CalendarBuilder.databaseName
        case (.garnet, .contacts): return ContactsBuilder.databaseName
        case (.garnet, .tasks): return TasksBuilder.databaseName
        case (.garnet, .memos): return MemosBuilder.databaseName
        case (.classic, .calendar): return ClassicDatebook.databaseName
        case (.classic, .contacts): return ClassicAddress.databaseName
        case (.classic, .tasks): return ClassicToDo.databaseName
        case (.classic, .memos): return ClassicMemo.databaseName
        case (.cobalt, .calendar): return "DateBookDBS"
        case (.cobalt, .contacts): return "AddressDBS"
        case (.cobalt, .tasks): return "ToDoDBS"
        case (.cobalt, .memos): return "MemoDBS"
        }
    }

    public func creator(_ kind: Kind) -> String {
        switch (self, kind) {
        case (.garnet, .calendar): return "PDat"
        case (.garnet, .contacts): return "PAdd"
        case (.garnet, .tasks): return "PTod"
        case (.garnet, .memos): return MemosBuilder.creator
        case (.classic, .calendar): return ClassicDatebook.creator
        case (.classic, .contacts): return ClassicAddress.creator
        case (.classic, .tasks): return ClassicToDo.creator
        case (.classic, .memos): return ClassicMemo.creator
        case (.cobalt, .calendar): return "dats"
        case (.cobalt, .contacts): return "adrs"
        case (.cobalt, .tasks): return "tdos"
        case (.cobalt, .memos): return "mems"
        }
    }

    /// The kind of a database of any family, by name.
    public static func kind(ofDatabase name: String) -> Kind? {
        for family in all {
            for kind in Kind.allCases where family.databaseName(kind) == name { return kind }
        }
        return nil
    }

    /// The family a database name belongs to.
    public static func family(ofDatabase name: String) -> PalmPIMFamily? {
        for family in all {
            for kind in Kind.allCases where family.databaseName(kind) == name { return family }
        }
        return nil
    }

    // MARK: Records at the edge

    /// Bytes of text one memo holds: 4 KB on Memo Pad, 32 KB on Memos, a
    /// 65534-byte VarChar less its NUL on Cobalt.
    public var memoTextLimit: Int {
        switch self {
        case .classic: return ClassicMemo.textLimit
        case .garnet: return 32767
        case .cobalt: return 65533
        }
    }

    /// The Garnet record for a record read from the Palm.
    public func garnetRecord(_ data: Data, kind: Kind) throws -> Data {
        guard self == .classic else { return data }
        switch kind {
        case .calendar: return try ClassicDatebook.calendarEvent(from: data).encode()
        case .contacts: return try ClassicAddress(data: data).contact.encode()
        case .tasks: return try ClassicToDo(data: data).palmTask.encode()
        case .memos: return try PalmMemo(data: data).encode()   // the same record on both
        }
    }

    /// The record the Palm gets for a Garnet record.
    public func deviceRecord(_ data: Data, kind: Kind) throws -> Data {
        guard self == .classic else { return data }
        switch kind {
        case .calendar: return ClassicDatebook.limit(try CalendarEvent(data: data)).encode()
        case .contacts: return ClassicAddress(try Contact(data: data)).encode()
        case .tasks: return ClassicToDo(try PalmTask(data: data)).encode()
        case .memos: return ClassicMemo.limit(try PalmMemo(data: data)).encode()
        }
    }

    /// Records read from the Palm as Garnet records. One that does not
    /// convert keeps its bytes: the engine cannot read it either, so it
    /// goes back onto the Palm as it is (`SyncPlan.opaque`).
    public func garnetRecords(_ records: [PalmRecordIn], kind: Kind) -> [PalmRecordIn] {
        guard self == .classic else { return records }
        return records.map { record in
            var r = record
            if let converted = try? garnetRecord(record.data, kind: kind) { r.data = converted }
            return r
        }
    }

    /// What the Palm can hold of a Garnet record: the Mac's items pass
    /// through this before they are compared with the Palm's.
    public func limit(_ event: CalendarEvent) -> CalendarEvent {
        self == .classic ? ClassicDatebook.limit(event) : event
    }

    public func limit(_ contact: Contact) -> Contact {
        self == .classic ? ClassicAddress.limit(contact) : contact
    }

    public func limit(_ task: PalmTask) -> PalmTask {
        self == .classic ? ClassicToDo.limit(task) : task
    }

    /// A memo cut to what this Palm's application holds; its text is
    /// otherwise left alone.
    public func limit(_ memo: PalmMemo) -> PalmMemo {
        PalmMemo(text: PalmMemo.truncated(memo.text, maxBytes: memoTextLimit))
    }

    /// The limit as the Mac writers take it: nil for Garnet, where the
    /// Palm holds every shared field.
    public var eventLimit: (@Sendable (SyncedEvent) -> SyncedEvent)? {
        guard self == .classic else { return nil }
        return { var e = $0; e.location = nil; return e }
    }

    public var contactLimit: (@Sendable (SyncedContact) -> SyncedContact)? {
        guard self == .classic else { return nil }
        return { item in
            var record = Contact()
            item.apply(to: &record)
            return SyncedContact(ClassicAddress.limit(record), category: item.category)
        }
    }

    public var taskLimit: (@Sendable (SyncedTask) -> SyncedTask)? {
        guard self == .classic else { return nil }
        return { item in
            var record = PalmTask(title: item.title ?? "")
            item.apply(to: &record)
            return SyncedTask(ClassicToDo.limit(record), category: item.category)
        }
    }

    /// The memo limit as the Mac writer takes it. Unlike the other kinds
    /// this applies to a Garnet Palm as well: Memos has a limit too, and
    /// the Mac's notes have formatting, spacing and characters no memo
    /// holds (`PalmMemo.limited`).
    public var memoLimit: @Sendable (SyncedMemo) -> SyncedMemo {
        let maxBytes = memoTextLimit
        return { SyncedMemo(text: PalmMemo.limited($0.text, maxBytes: maxBytes), category: $0.category) }
    }

    /// The Mac's items limited to what the Palm can hold, so that what
    /// comes back from the Palm compares equal.
    public func limited(_ items: [MacSyncItem<SyncedEvent>]) -> [MacSyncItem<SyncedEvent>] {
        guard self == .classic else { return items }
        return items.map { item in
            var i = item
            guard let data = item.palmRecord, let record = try? CalendarEvent(data: data) else { return i }
            let limited = ClassicDatebook.limit(record)
            i.item = SyncedEvent(limited, category: item.item.category)
            i.palmRecord = limited.encode()
            return i
        }
    }

    public func limited(_ items: [MacSyncItem<SyncedContact>]) -> [MacSyncItem<SyncedContact>] {
        guard self == .classic else { return items }
        return items.map { item in
            var i = item
            guard let data = item.palmRecord, let record = try? Contact(data: data) else { return i }
            let limited = ClassicAddress.limit(record)
            i.item = SyncedContact(limited, category: item.item.category)
            i.palmRecord = limited.encode()
            return i
        }
    }

    public func limited(_ items: [MacSyncItem<SyncedTask>]) -> [MacSyncItem<SyncedTask>] {
        guard self == .classic else { return items }
        return items.map { item in
            var i = item
            guard let data = item.palmRecord, let record = try? PalmTask(data: data) else { return i }
            let limited = ClassicToDo.limit(record)
            i.item = SyncedTask(limited, category: item.item.category)
            i.palmRecord = limited.encode()
            return i
        }
    }

    /// The builder already limits a note to what Memos holds; a classic
    /// Palm's Memo Pad holds less. The same cut as `memoLimit`, so the
    /// writer sees the Mac's notes as the engine does.
    public func limited(_ items: [MacSyncItem<SyncedMemo>]) -> [MacSyncItem<SyncedMemo>] {
        guard self == .classic else { return items }
        let limit = memoLimit
        return items.map { item in
            var i = item
            i.item = limit(item.item)
            i.palmRecord = PalmMemo(text: i.item.text).encode()
            return i
        }
    }

    // MARK: Whole databases

    /// A database built for the Garnet application as the Palm of this
    /// family installs it: its name, creator and AppInfo, every record
    /// converted; a record that does not convert (one the engine carried
    /// through unread) keeps its bytes.
    public func deviceDatabase(_ db: PalmDatabase, kind: Kind, appInfo: Data?) -> PalmDatabase {
        guard self == .classic else { return db }
        var out = db
        out.name = databaseName(kind)
        out.creator = creator(kind)
        out.appInfo = appInfo
        out.records = db.records.map { record in
            var r = record
            if let converted = try? deviceRecord(record.data, kind: kind) { r.data = converted }
            return r
        }
        return out
    }

    /// The AppInfo a classic database gets: the Palm's own block with the
    /// categories replaced, or a new one.
    public func classicAppInfo(kind: Kind, existing: Data?, categories: CategoryAppInfo, startOfWeek: UInt8 = 0) -> Data {
        switch kind {
        case .calendar:
            var info = existing.flatMap { try? ClassicDatebookAppInfo(data: $0) } ?? ClassicDatebookAppInfo(startOfWeek: startOfWeek)
            info.categories = categories
            return info.encode()
        case .contacts:
            var info = existing.flatMap { try? ClassicAddressAppInfo(data: $0) } ?? ClassicAddressAppInfo()
            info.categories = categories
            return info.encode()
        case .tasks:
            var info = existing.flatMap { try? ClassicToDoAppInfo(data: $0) } ?? ClassicToDoAppInfo()
            info.categories = categories
            return info.encode()
        case .memos:
            var info = existing.flatMap { try? MemoAppInfo(data: $0) }
                ?? MemoAppInfo(internalSize: MemoAppInfo.classicInternalSize)
            info.categories = categories
            return info.encode()
        }
    }

    /// The categories of a database's AppInfo block, of any family. A
    /// Cobalt database has none: `CobaltDatabaseRead.appInfo` is the Garnet
    /// block built from its categories.
    public func categories(ofAppInfo data: Data, kind: Kind) -> CategoryAppInfo? {
        switch (self, kind) {
        case (.garnet, .calendar), (.cobalt, .calendar): return (try? CalendarAppInfo(data: data))?.categories
        case (.garnet, .contacts), (.cobalt, .contacts): return (try? ContactAppInfo(data: data))?.categories
        case (.garnet, .tasks), (.cobalt, .tasks): return (try? TaskAppInfo(data: data))?.categories
        case (.classic, .calendar): return (try? ClassicDatebookAppInfo(data: data))?.categories
        case (.classic, .contacts): return (try? ClassicAddressAppInfo(data: data))?.categories
        case (.classic, .tasks): return (try? ClassicToDoAppInfo(data: data))?.categories
        case (_, .memos): return (try? MemoAppInfo(data: data))?.categories
        }
    }

    /// Whether a record read from the Palm reads back byte for byte through
    /// the family's codec (the check after a one-way install).
    public func readsBack(_ data: Data, kind: Kind) -> Bool {
        switch (self, kind) {
        case (.garnet, .calendar), (.cobalt, .calendar): return (try? CalendarEvent(data: data))?.encode() == data
        case (.garnet, .contacts), (.cobalt, .contacts): return (try? Contact(data: data))?.encode() == data
        case (.garnet, .tasks), (.cobalt, .tasks): return (try? PalmTask(data: data))?.encode() == data
        case (.classic, .calendar): return (try? ClassicDatebook.calendarEvent(from: data))?.encode() == data
        case (.classic, .contacts): return (try? ClassicAddress(data: data))?.encode() == data
        case (.classic, .tasks): return (try? ClassicToDo(data: data))?.encode() == data
        case (_, .memos): return (try? PalmMemo(data: data))?.encode() == data
        }
    }
}

extension PalmOSVersion {
    /// The PIM family of a Palm OS version: Garnet from 5.2 on, classic
    /// before (Palm OS 5.0 and 5.1 devices still run Datebook, Address and
    /// To Do).
    public var pimFamily: PalmPIMFamily { hasGarnetPIM ? .garnet : .classic }
}
