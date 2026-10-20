import Foundation

/// What identifies an item on the Mac side: the series (EventKit's
/// calendarItemIdentifier) and, for an occurrence that stands on its own on
/// the Palm (edited on the Mac, or expanded because the Palm cannot express
/// the rule), the date the rule put it on.
public struct MacKey: Hashable, Codable, Sendable {
    public var seriesID: String
    public var occurrence: Date?

    public init(seriesID: String, occurrence: Date? = nil) {
        self.seriesID = seriesID
        self.occurrence = occurrence
    }
}

/// One synced item, as both sides agreed on it at the last sync. The merge
/// compares each side against `base`; `palmRecord` keeps the Palm's bytes so
/// an update can be written without losing the blobs the Palm put there.
public struct MirrorEntry: Equatable, Codable, Sendable {
    public var palmID: UInt32
    public var mac: MacKey
    public var base: SyncedEvent
    public var palmRecord: Data
    /// The Mac owns this item (an expanded occurrence of a rule the Palm
    /// cannot express): edits made on the Palm are logged and undone.
    public var macOwned: Bool

    public init(palmID: UInt32, mac: MacKey, base: SyncedEvent, palmRecord: Data, macOwned: Bool = false) {
        self.palmID = palmID
        self.mac = mac
        self.base = base
        self.palmRecord = palmRecord
        self.macOwned = macOwned
    }
}

/// The sync state for one Palm database on one device. Lose it and the next
/// sync is a slow one that matches records by content. Kept as a JSON file
/// next to the device's backup: small, readable, diffable.
public struct SyncMirror: Equatable, Codable, Sendable {
    /// This Mac's ID as written into the Palm's lastSyncPC: when the Palm
    /// reports the same one, its modified flags are trustworthy.
    public var pcID: UInt32
    public var lastSync: Date?
    public var entries: [MirrorEntry]

    public init(pcID: UInt32, lastSync: Date? = nil, entries: [MirrorEntry] = []) {
        self.pcID = pcID
        self.lastSync = lastSync
        self.entries = entries
    }

    /// A fresh ID for a Mac that has none yet: anything but 0, which the
    /// Palm uses for "never synced".
    public static func newPCID() -> UInt32 {
        max(1, UInt32.random(in: 1...UInt32.max))
    }

    public static func load(from url: URL) throws -> SyncMirror {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(SyncMirror.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
