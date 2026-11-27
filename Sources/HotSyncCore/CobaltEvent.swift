import Foundation

// The events of hotsync-session's Cobalt commands (`cobaltlist`,
// `cobaltopen`, `cobaltclose`, `cobalttables`, `cobaltschema`,
// `cobaltcategories`, `cobaltsyncstate`, `cobaltrowcount`, `cobaltreadall`,
// `cobaltreadrows`): Palm OS Cobalt 6.1 keeps its PIM data in schema
// databases (tables of typed columns, rows with a 32-bit id and a set of
// categories), reached through Cobalt-only DLP commands. The tool hands the
// column bytes over undecoded; PalmSync's CobaltRecords does the decoding.

/// One column of a schema database's table, as 0x76 (schema) reports it.
public struct CobaltColumn: Equatable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    /// SchemaDatabases.h: UInt8 1, UInt16 2, UInt32 3, UInt64 4, Int8 5,
    /// Int16 6, Int32 7, Int64 8, Float 9, Double 0xA, Boolean 0xB,
    /// DateTime 0xC, Date 0xD, Time 0xE, Char 0xF, VarChar 0x10, Blob 0x11,
    /// DateTimeSecs 0x12; 0x80 set: a vector of the element type.
    public let type: UInt8
    public let maxSize: Int
    /// dynamic 1, non-syncable 2, writable 4
    public let attrib: Int

    public init(id: UInt32, name: String, type: UInt8, maxSize: Int, attrib: Int = 0) {
        self.id = id
        self.name = name
        self.type = type
        self.maxSize = maxSize
        self.attrib = attrib
    }
}

/// A category of a schema database (0x98): Cobalt categories are ids with
/// names; "Unfiled" is id 0 and is never listed.
public struct CobaltCategory: Equatable, Hashable, Sendable {
    public let id: UInt32
    public let name: String

    public init(id: UInt32, name: String) {
        self.id = id
        self.name = name
    }

    public static let unfiledId: UInt32 = 0
}

/// A row of a schema database's table, from the 0xAE stream. The column
/// bytes are as the device stores them (little-endian), keyed by column id.
public struct CobaltRow: Equatable, Sendable {
    public let rowId: UInt32
    /// row attributes: 0x80 deleted, 0x01 archived
    public let attr: UInt8
    /// sync status bits: 1/2 modified, 4 deleted, 8 archived
    public let syncStatus: UInt8
    public let modified: Bool
    public let deleted: Bool
    public let archived: Bool
    /// the row's presence flags and error as the device reported them
    /// (`cobaltreadrows` reports an unknown id with err 5)
    public let present: Int
    public let err: Int
    public let categories: [UInt32]
    public let columns: [UInt32: Data]
    /// columns the device reported with an error code, by id
    public let columnErrors: [UInt32: Int]

    public init(rowId: UInt32, attr: UInt8 = 0, syncStatus: UInt8 = 0, modified: Bool? = nil, deleted: Bool? = nil,
                archived: Bool? = nil, present: Int = 0, err: Int = 0, categories: [UInt32] = [],
                columns: [UInt32: Data] = [:], columnErrors: [UInt32: Int] = [:]) {
        self.rowId = rowId
        self.attr = attr
        self.syncStatus = syncStatus
        self.modified = modified ?? ((syncStatus & 3) != 0)
        self.deleted = deleted ?? ((attr & 0x80) != 0 || (syncStatus & 4) != 0)
        self.archived = archived ?? ((attr & 0x01) != 0 || (syncStatus & 8) != 0)
        self.present = present
        self.err = err
        self.categories = categories
        self.columns = columns
        self.columnErrors = columnErrors
    }

    public subscript(column id: UInt32) -> Data? { columns[id] }
}

/// A database of the Cobalt store, from 0x7F (`cobaltlist`).
public struct CobaltDatabaseInfo: Equatable, Sendable {
    public let name: String
    public let type: String
    public let creator: String
    public let attr: Int
    /// attr 0x1000: a schema database
    public let isSchema: Bool
    /// attr 0x2000: a secure (trust-gated) database
    public let isSecure: Bool
    public let version: Int
    public let modificationNumber: Int

    public init(name: String, type: String, creator: String, attr: Int, version: Int = 0, modificationNumber: Int = 0) {
        self.name = name
        self.type = type
        self.creator = creator
        self.attr = attr
        isSchema = (attr & 0x1000) != 0
        isSecure = (attr & 0x2000) != 0
        self.version = version
        self.modificationNumber = modificationNumber
    }
}

/// The sync state of an open schema database (0x87).
public struct CobaltSyncState: Equatable, Sendable {
    public let format: UInt32
    public let syncId: UInt32
    public let clock: Int
    public let rowsPurge: Int
    public let schemasPurge: Int
    public let categoryPurge: Int

    public init(format: UInt32, syncId: UInt32, clock: Int, rowsPurge: Int = 0, schemasPurge: Int = 0, categoryPurge: Int = 0) {
        self.format = format
        self.syncId = syncId
        self.clock = clock
        self.rowsPurge = rowsPurge
        self.schemasPurge = schemasPurge
        self.categoryPurge = categoryPurge
    }
}

public enum CobaltEvent: Equatable, Sendable {
    /// one per database of the store, then `listDone`
    case database(CobaltDatabaseInfo)
    case listDone(count: Int)
    /// `handle` names the open database in every command that follows
    case opened(handle: Int, name: String, creator: String, mode: Int)
    /// `token`: the sync token when the close asked for one (flag 0x20)
    case closed(handle: Int, name: String, token: Data?)
    /// one per table of the database, then `tablesDone`
    case table(handle: Int, name: String, columns: Int)
    case tablesDone(handle: Int, count: Int)
    /// one per column of the table, then `schemaDone`
    case column(handle: Int, table: String, CobaltColumn)
    case schemaDone(handle: Int, table: String, count: Int)
    /// one per category, then `categoriesDone`
    case category(handle: Int, CobaltCategory)
    case categoriesDone(handle: Int, count: Int)
    /// nil: the database is not syncable (no sync state)
    case syncState(handle: Int, CobaltSyncState?)
    case rowCount(handle: Int, table: String, rows: Int)
    /// one per row read, then `rowsDone`; `table` is empty for
    /// `cobaltreadrows` when the device did not name it
    case row(handle: Int, table: String, CobaltRow)
    case rowsDone(handle: Int, table: String, rows: Int, tables: Int)

    private struct DatabaseLine: Decodable {
        let name: String; let type: String; let creator: String; let attr: Int; let version: Int?; let modnum: Int?
    }
    private struct HandleLine: Decodable {
        let handle: Int; let name: String?; let creator: String?; let mode: Int?; let token: String?
        let table: String?; let columns: Int?; let count: Int?; let rows: Int?; let tables: Int?
        let id: UInt32?; let type: UInt8?; let attrib: Int?; let maxSize: Int?
        let syncable: Int?; let format: UInt32?; let syncId: UInt32?; let clock: Int?
        let rowsPurge: Int?; let schemasPurge: Int?; let categoryPurge: Int?
    }
    private struct RowLine: Decodable {
        struct Column: Decodable { let id: UInt32; let size: Int?; let err: Int?; let hex: String? }
        let handle: Int; let table: String?; let rowId: UInt32; let attr: Int?; let syncStatus: Int?
        let modified: Int?; let deleted: Int?; let archived: Int?; let present: Int?; let err: Int?
        let categories: [UInt32]?; let columns: [Column]?
    }

    /// The event of one `cobalt...` output line; nil for a line that is not
    /// one or lacks a field the event needs.
    static func parse(event: String, data: Data) -> CobaltEvent? {
        let decoder = JSONDecoder()
        switch event {
        case "cobaltDatabase":
            guard let l = try? decoder.decode(DatabaseLine.self, from: data) else { return nil }
            return .database(CobaltDatabaseInfo(name: l.name, type: l.type, creator: l.creator, attr: l.attr,
                                                version: l.version ?? 0, modificationNumber: l.modnum ?? 0))
        case "cobaltListDone":
            // the one event without a handle
            struct CountLine: Decodable { let count: Int? }
            return .listDone(count: (try? decoder.decode(CountLine.self, from: data))?.count ?? 0)
        case "cobaltRow":
            guard let l = try? decoder.decode(RowLine.self, from: data) else { return nil }
            var columns: [UInt32: Data] = [:]
            var errors: [UInt32: Int] = [:]
            for c in l.columns ?? [] {
                columns[c.id] = Data(hex: c.hex ?? "") ?? Data()
                if let err = c.err, err != 0 { errors[c.id] = err }
            }
            let row = CobaltRow(rowId: l.rowId, attr: UInt8(clamping: l.attr ?? 0), syncStatus: UInt8(clamping: l.syncStatus ?? 0),
                                modified: l.modified.map { $0 != 0 }, deleted: l.deleted.map { $0 != 0 },
                                archived: l.archived.map { $0 != 0 }, present: l.present ?? 0, err: l.err ?? 0,
                                categories: l.categories ?? [], columns: columns, columnErrors: errors)
            return .row(handle: l.handle, table: l.table ?? "", row)
        default:
            break
        }
        guard let l = try? decoder.decode(HandleLine.self, from: data) else { return nil }
        switch event {
        case "cobaltOpened":
            return .opened(handle: l.handle, name: l.name ?? "", creator: l.creator ?? "", mode: l.mode ?? 0)
        case "cobaltClosed":
            return .closed(handle: l.handle, name: l.name ?? "", token: l.token.flatMap { Data(hex: $0) })
        case "cobaltTable":
            guard let name = l.name else { return nil }
            return .table(handle: l.handle, name: name, columns: l.columns ?? 0)
        case "cobaltTablesDone":
            return .tablesDone(handle: l.handle, count: l.count ?? 0)
        case "cobaltColumn":
            guard let id = l.id, let name = l.name, let type = l.type else { return nil }
            return .column(handle: l.handle, table: l.table ?? "",
                           CobaltColumn(id: id, name: name, type: type, maxSize: l.maxSize ?? 0, attrib: l.attrib ?? 0))
        case "cobaltSchemaDone":
            return .schemaDone(handle: l.handle, table: l.table ?? "", count: l.count ?? 0)
        case "cobaltCategory":
            guard let id = l.id, let name = l.name else { return nil }
            return .category(handle: l.handle, CobaltCategory(id: id, name: name))
        case "cobaltCategoriesDone":
            return .categoriesDone(handle: l.handle, count: l.count ?? 0)
        case "cobaltSyncState":
            guard (l.syncable ?? 0) != 0, let format = l.format, let syncId = l.syncId else {
                return .syncState(handle: l.handle, nil)
            }
            return .syncState(handle: l.handle, CobaltSyncState(format: format, syncId: syncId, clock: l.clock ?? 0,
                                                                rowsPurge: l.rowsPurge ?? 0, schemasPurge: l.schemasPurge ?? 0,
                                                                categoryPurge: l.categoryPurge ?? 0))
        case "cobaltRowCount":
            return .rowCount(handle: l.handle, table: l.table ?? "", rows: l.rows ?? 0)
        case "cobaltRowsDone":
            return .rowsDone(handle: l.handle, table: l.table ?? "", rows: l.rows ?? 0, tables: l.tables ?? 0)
        default:
            return nil
        }
    }
}

extension Data {
    /// The bytes of a hex string (two digits per byte, either case); nil for
    /// anything else. "" is empty data.
    public init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let high = Self.hexValue(chars[i]), let low = Self.hexValue(chars[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
            i += 2
        }
        self.init(bytes)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
