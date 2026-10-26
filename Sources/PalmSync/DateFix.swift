import Foundation

/// DateFix (a Palm-side patch by the hotsync-macos author) moves Palm OS's
/// date epoch from 1904 to a later start year, so a Palm keeps a working
/// calendar after 2031. Its stored dates and its clock are then shifted by
/// `startYear - 1904` years, and a HotSync sees the shifted values. This
/// converts at the bridge: records leaving the Palm get the years added,
/// records going to the Palm get them taken away, so the engine, the
/// mirror and the Mac work in real years throughout.
public enum DateFix {
    /// Which record layout a database has, by its creator.
    public enum Kind {
        case calendar, contacts, tasks

        public init?(creator: String) {
            switch creator {
            case "PDat": self = .calendar
            case "PAdd": self = .contacts
            case "PTod": self = .tasks
            default: return nil
            }
        }
    }

    /// DateFix moves the clock by whole 4-year blocks (1461 days each), so
    /// leap years stay aligned; start years are 1904, 1908, … 1972.
    public static func offsetDays(startYear: Int) -> Int {
        max(0, (startYear - 1904) / 4) * 1461
    }

    /// A date shifted by `years`; one that would fall before the Palm's
    /// window becomes the window's first day, as DateFix itself does.
    public static func shift(_ date: PalmDate, years: Int) -> PalmDate {
        var d = date
        d.year += years
        if d.year < 1904 { return PalmDate(year: 1904, month: 1, day: 1) }
        return d
    }

    /// The record with every date it holds shifted by `years`. A record the
    /// codec cannot read is returned as it is.
    public static func shift(_ data: Data, kind: Kind, years: Int) -> Data {
        guard years != 0 else { return data }
        switch kind {
        case .calendar:
            guard var event = try? CalendarEvent(data: data) else { return data }
            event.date = shift(event.date, years: years)
            if let end = event.repeatRule?.endDate { event.repeatRule?.endDate = shift(end, years: years) }
            event.exceptions = event.exceptions.map { shift($0, years: years) }
            return event.encode()
        case .tasks:
            guard var task = try? PalmTask(data: data) else { return data }
            task.dueDate = task.dueDate.map { shift($0, years: years) }
            task.completedDate = task.completedDate.map { shift($0, years: years) }
            if let (start, rule) = task.repeatRule {
                var r = rule
                r.endDate = r.endDate.map { shift($0, years: years) }
                task.repeatRule = (shift(start, years: years), r)
            }
            return task.encode()
        case .contacts:
            guard var contact = try? Contact(data: data) else { return data }
            if let birthday = contact.birthday { contact.birthday?.date = shift(birthday.date, years: years) }
            // the anniversary blob: a dirty word, then the packed date
            contact.blobs = contact.blobs.map { blob in
                guard blob.type == Contact.anniversaryBlobType, blob.data.count >= 4 else { return blob }
                var bytes = [UInt8](blob.data)
                let packed = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
                guard packed != PalmDate.none else { return blob }
                let moved = shift(PalmDate(packed: packed), years: years).packed
                bytes[2] = UInt8(moved >> 8)
                bytes[3] = UInt8(moved & 0xFF)
                return PalmBlob(type: blob.type, data: Data(bytes))
            }
            return contact.encode()
        }
    }

    /// A date DateFix could not represent (before its start year) is stored
    /// as the window's first day. Read back, that is no edit: where the
    /// mirror knows the real date and it lies before the window, the record
    /// gets it back, so the clamp never travels to the Mac. Contacts
    /// birthdays are the only such dates in practice.
    public static func unclamp<Item: SyncedItem>(_ data: Data, kind: Kind, startYear: Int, base: Item) -> Data {
        guard kind == .contacts, let base = base as? SyncedContact, let real = base.birthday, real.year < startYear,
              var contact = try? Contact(data: data), contact.birthday?.date == PalmDate(year: startYear, month: 1, day: 1)
        else { return data }
        contact.birthday?.date = real
        return contact.encode()
    }

    /// Every record of a PIM database shifted; other databases untouched.
    public static func shift(_ database: PalmDatabase, years: Int) -> PalmDatabase {
        guard years != 0, let kind = Kind(creator: database.creator) else { return database }
        var db = database
        db.records = db.records.map { record in
            var r = record
            r.data = shift(record.data, kind: kind, years: years)
            return r
        }
        return db
    }
}
