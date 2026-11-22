import Foundation

// The record and AppInfo formats of the Palm OS 1-5.1 PIM applications
// (Datebook, Address, To Do), as pilot-link's datebook.c, address.c and
// todo.c read and write them. The sync works on the Garnet records
// (CalendarEvent, Contact, PalmTask) throughout; these codecs convert at
// the edge, see `PalmPIMFamily`.

/// A Datebook record (database DatebookDB, creator date). Its layout is the
/// Calendar's without the location flag and the trailing blobs, so the
/// Calendar codec reads it as it is; this only says what must not be
/// written to a Datebook.
public enum ClassicDatebook {
    public static let databaseName = "DatebookDB"
    public static let creator = "date"

    /// The Calendar record a Datebook can hold: no location, no blobs.
    public static func limit(_ event: CalendarEvent) -> CalendarEvent {
        var e = event
        e.location = nil
        e.blobs = []
        return e
    }

    /// A Datebook record read as a Calendar record; nil for bytes a Datebook
    /// would not have written (a location, blobs).
    public static func calendarEvent(from data: Data) throws -> CalendarEvent {
        let event = try CalendarEvent(data: data)
        guard event.location == nil, event.blobs.isEmpty else {
            throw PalmFormatError.invalidValue(field: "datebook.flags", value: Int(data.count > 6 ? data[6] : 0))
        }
        return event
    }
}

/// The AppInfo block of DatebookDB: the category block and the first day
/// of the week, 280 bytes.
public struct ClassicDatebookAppInfo: Equatable, Sendable {
    public var categories: CategoryAppInfo
    /// 0 = Sunday, 1 = Monday
    public var startOfWeek: UInt8
    public var padding: UInt8

    public static let size = CategoryAppInfo.size + 2

    public init(categories: CategoryAppInfo = CategoryAppInfo(), startOfWeek: UInt8 = 0) {
        self.categories = categories
        self.startOfWeek = startOfWeek
        padding = 0
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        categories = try CategoryAppInfo(bytes: try r.slice(CategoryAppInfo.size))
        startOfWeek = try r.u8()
        padding = (try? r.u8()) ?? 0
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.append(categories.encode())
        w.u8(startOfWeek)
        w.u8(padding)
        return w.data
    }
}

/// An Address record (database AddressDB, creator addr).
///
/// Layout (big-endian):
///
///      0  labels           UInt32: phone1 bits 0-3 … phone5 bits 16-19,
///                          showPhone bits 20-23
///      4  contents         UInt32, bit i = field i (0-18) is present
///      8  companyOffset    from this byte to the company field, 0 if none
///      9  fields           NUL-terminated, in field order, present ones only
///
/// The phone label values are the Contacts application's: work 0, home 1,
/// fax 2, other 3, e-mail 4, main 5, pager 6, mobile 7.
public struct ClassicAddress: Equatable, Sendable {
    public enum Field: Int, CaseIterable, Sendable {
        case lastName, firstName, company
        case phone1, phone2, phone3, phone4, phone5
        case address, city, state, zip, country
        case title
        case custom1, custom2, custom3, custom4
        case note
    }

    public static let databaseName = "AddressDB"
    public static let creator = "addr"
    public static let fieldCount = 19
    public static let phoneCount = 5

    public var phoneLabels: [UInt8]
    public var showPhone: UInt8
    /// Text of each field, nil when absent. An empty text is written as
    /// absent, as the Address application and pilot-link do.
    public var fields: [String?]

    public init(fields: [Field: String] = [:], phoneLabels: [UInt8] = [0, 1, 2, 3, 4], showPhone: UInt8 = 0) {
        self.phoneLabels = (phoneLabels + [0, 0, 0, 0, 0]).prefix(Self.phoneCount).map { $0 & 0x0F }
        self.showPhone = showPhone & 0x0F
        self.fields = [String?](repeating: nil, count: Self.fieldCount)
        for (field, text) in fields { self.fields[field.rawValue] = text }
    }

    public subscript(field: Field) -> String? {
        get { fields[field.rawValue] }
        set { fields[field.rawValue] = newValue }
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        let labels = try r.u32()
        let contents = try r.u32()
        _ = try r.u8()  // companyOffset, derived from the fields
        phoneLabels = (0..<Self.phoneCount).map { UInt8((labels >> (4 * UInt32($0))) & 0x0F) }
        showPhone = UInt8((labels >> 20) & 0x0F)
        fields = []
        for i in 0..<Self.fieldCount {
            fields.append(contents & (1 << UInt32(i)) != 0 ? try r.cString() : nil)
        }
        guard r.isAtEnd else { throw PalmFormatError.trailingBytes(count: r.remaining) }
    }

    public func encode() -> Data {
        var w = ByteWriter()
        var labels: UInt32 = 0
        for (i, label) in phoneLabels.prefix(Self.phoneCount).enumerated() {
            labels |= UInt32(label & 0x0F) << (4 * UInt32(i))
        }
        labels |= UInt32(showPhone & 0x0F) << 20
        w.u32(labels)
        var contents: UInt32 = 0
        var offset: UInt8 = 0
        var body = ByteWriter()
        for i in 0..<Self.fieldCount {
            guard let text = fields[i], !text.isEmpty else { continue }
            if i == Field.company.rawValue { offset = UInt8(clamping: body.bytes.count + 1) }
            contents |= 1 << UInt32(i)
            body.cString(text)
        }
        w.u32(contents)
        w.u8(offset)
        w.append(body.bytes)
        return w.data
    }

    // MARK: The Contacts record it stands for

    static let contactFields: [(Field, Contact.Field)] = [
        (.lastName, .lastName), (.firstName, .firstName), (.company, .company),
        (.phone1, .phone1), (.phone2, .phone2), (.phone3, .phone3), (.phone4, .phone4), (.phone5, .phone5),
        (.address, .address1), (.city, .city1), (.state, .state1), (.zip, .zip1), (.country, .country1),
        (.title, .title),
        (.custom1, .custom1), (.custom2, .custom2), (.custom3, .custom3), (.custom4, .custom4),
        (.note, .note),
    ]

    /// The same contact as a Contacts record: the fields the Address has,
    /// address 1 labelled home (the Address has no label), nothing else.
    public var contact: Contact {
        var c = Contact()
        for (mine, theirs) in Self.contactFields {
            if let text = self[mine], !text.isEmpty { c[theirs] = text }
        }
        for i in 0..<Self.phoneCount { c.setPhoneLabel(i, phoneLabels[i]) }
        c.showPhone = showPhone
        return c
    }

    /// The Address record for a Contacts record, keeping what an Address
    /// can hold (see `limit`).
    public init(_ contact: Contact) {
        self.init()
        for (mine, theirs) in Self.contactFields {
            if let text = contact[theirs], !text.isEmpty { self[mine] = text }
        }
        for i in 0..<Self.phoneCount { phoneLabels[i] = contact.phoneLabel(i) & 0x0F }
        showPhone = min(contact.showPhone, UInt8(Self.phoneCount - 1))
    }

    /// The Contacts record an Address can hold: five phones, one address
    /// labelled home, four custom fields, no IM, web site, birthday or
    /// blobs. What comes back from an Address reads as exactly this.
    public static func limit(_ contact: Contact) -> Contact {
        ClassicAddress(contact).contact
    }
}

/// The AppInfo block of AddressDB: the category block, which labels were
/// renamed, the 22 field labels, the country and the sort order, 638 bytes.
public struct ClassicAddressAppInfo: Equatable, Sendable {
    public var categories: CategoryAppInfo
    public var renamedLabels: UInt32
    public var labels: [String]
    public var country: UInt16
    public var sortByCompany: Bool
    public var sortPadding: UInt8

    public static let labelCount = 22
    public static let labelWidth = 16
    public static let size = CategoryAppInfo.size + 4 + labelCount * labelWidth + 4

    /// The labels an English Palm ships with.
    public static let defaultLabels = [
        "Last name", "First name", "Company", "Work", "Home", "Fax", "Other", "E-mail",
        "Address", "City", "State", "Zip Code", "Country", "Title",
        "Custom 1", "Custom 2", "Custom 3", "Custom 4", "Note", "Main", "Pager", "Mobile",
    ]

    public init(categories: CategoryAppInfo = CategoryAppInfo(), labels: [String] = ClassicAddressAppInfo.defaultLabels,
                country: UInt16 = 0, sortByCompany: Bool = false) {
        self.categories = categories
        renamedLabels = 0
        self.labels = labels
        self.country = country
        self.sortByCompany = sortByCompany
        sortPadding = 0
    }

    public init(data: Data) throws {
        guard data.count >= Self.size else { throw PalmFormatError.invalidValue(field: "appInfo.size", value: data.count) }
        var r = ByteReader(data)
        categories = try CategoryAppInfo(bytes: try r.slice(CategoryAppInfo.size))
        renamedLabels = try r.u32()
        labels = try (0..<Self.labelCount).map { _ in try r.fixedString(Self.labelWidth) }
        country = try r.u16()
        sortByCompany = try r.u8() != 0
        sortPadding = try r.u8()
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.append(categories.encode())
        w.u32(renamedLabels)
        for i in 0..<Self.labelCount { w.fixedString(i < labels.count ? labels[i] : "", width: Self.labelWidth) }
        w.u16(country)
        w.u8(sortByCompany ? 1 : 0)
        w.u8(sortPadding)
        return w.data
    }

    /// The eight phone labels a record's phone values index.
    public var phoneLabels: [String] {
        guard labels.count >= Self.labelCount else { return [] }
        return Array(labels[3...7]) + Array(labels[19...21])
    }
}

/// A To Do record (database ToDoDB, creator todo).
///
/// Layout (big-endian):
///
///      0  dueDate          PalmDate, 0xFFFF for none
///      2  priority         1-5, bit 0x80 set when completed
///      3  description      NUL-terminated
///         note             NUL-terminated, present even when empty
public struct ClassicToDo: Equatable, Sendable {
    public static let databaseName = "ToDoDB"
    public static let creator = "todo"

    public var dueDate: PalmDate?
    public var completed: Bool
    public var priority: UInt8
    public var title: String
    public var note: String

    public init(title: String, note: String = "", priority: UInt8 = 1, dueDate: PalmDate? = nil, completed: Bool = false) {
        self.title = title
        self.note = note
        self.priority = priority
        self.dueDate = dueDate
        self.completed = completed
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        let due = try r.u16()
        dueDate = due == PalmDate.none ? nil : PalmDate(packed: due)
        let p = try r.u8()
        completed = p & 0x80 != 0
        priority = p & 0x7F
        title = try r.cString()
        note = try r.cString()
        guard r.isAtEnd else { throw PalmFormatError.trailingBytes(count: r.remaining) }
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.u16(dueDate?.packed ?? PalmDate.none)
        w.u8((priority & 0x7F) | (completed ? 0x80 : 0))
        w.cString(title)
        w.cString(note)
        return w.data
    }

    // MARK: The Tasks record it stands for

    /// A To Do knows only whether a task is done, not when. So that both
    /// sides agree without a date, a completed To Do counts as completed
    /// on its due day, or on this day when it has none.
    public static let completedWithoutDate = PalmDate(year: 1904, month: 1, day: 1)

    public static func completedDate(completed: Bool, dueDate: PalmDate?) -> PalmDate? {
        completed ? (dueDate ?? completedWithoutDate) : nil
    }

    public var palmTask: PalmTask {
        PalmTask(title: title, note: note, priority: priority, dueDate: dueDate,
                 completedDate: Self.completedDate(completed: completed, dueDate: dueDate))
    }

    public init(_ task: PalmTask) {
        self.init(title: task.title, note: task.note, priority: min(max(task.priority, 1), 5), dueDate: task.dueDate,
                  completed: task.completedDate != nil)
    }

    /// The Tasks record a To Do can hold: no alarm, no repeat, the
    /// completion date as `completedDate(completed:dueDate:)` says.
    public static func limit(_ task: PalmTask) -> PalmTask {
        ClassicToDo(task).palmTask
    }
}

/// The AppInfo block of ToDoDB: the category block, a dirty word and the
/// sort order, 282 bytes.
public struct ClassicToDoAppInfo: Equatable, Sendable {
    public var categories: CategoryAppInfo
    public var dirty: UInt16
    public var sortByPriority: Bool
    public var padding: UInt8

    public static let size = CategoryAppInfo.size + 4

    public init(categories: CategoryAppInfo = CategoryAppInfo(), sortByPriority: Bool = false) {
        self.categories = categories
        dirty = 0
        self.sortByPriority = sortByPriority
        padding = 0
    }

    public init(data: Data) throws {
        var r = ByteReader(data)
        categories = try CategoryAppInfo(bytes: try r.slice(CategoryAppInfo.size))
        dirty = (try? r.u16()) ?? 0
        sortByPriority = ((try? r.u8()) ?? 0) != 0
        padding = (try? r.u8()) ?? 0
    }

    public func encode() -> Data {
        var w = ByteWriter()
        w.append(categories.encode())
        w.u16(dirty)
        w.u8(sortByPriority ? 1 : 0)
        w.u8(padding)
        return w.data
    }
}
