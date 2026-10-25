import Foundation

/// A Palm record as the bridge delivers it (the `record` event).
public struct PalmRecordIn: Equatable, Sendable {
    public var id: UInt32
    /// dlpRecAttr*: deleted 0x80, dirty 0x40, busy 0x20, secret 0x10, archived 0x08
    public var attributes: UInt8
    public var category: Int
    public var data: Data

    public init(id: UInt32, attributes: UInt8 = 0, category: Int = 0, data: Data) {
        self.id = id
        self.attributes = attributes
        self.category = category
        self.data = data
    }

    public var isDeleted: Bool { attributes & 0x80 != 0 }
    public var isArchived: Bool { attributes & 0x08 != 0 }
}

/// What the Palm side handed over: every record (slow sync, `readall`) or
/// only the ones changed since the last sync (fast sync, `readmodified`).
public enum PalmSnapshot: Equatable, Sendable {
    case all([PalmRecordIn])
    case modified([PalmRecordIn])
}

/// What happens when both sides changed the same field of the same item
/// to different values; the Palm Desktop conduits had the same three.
public enum ConflictPolicy: String, Codable, CaseIterable, Sendable {
    /// the Mac's value, the Palm's goes to the log
    case macWins
    /// the Palm's value, the Mac's goes to the log
    case palmWins
    /// the Mac's value in the item, and the Palm's version becomes a second
    /// item on both sides, as the Palm Desktop did; nothing is lost
    case keepBoth
}

public struct SyncConflict: Equatable, Sendable {
    public var palmID: UInt32?
    public var mac: MacKey?
    public var title: String
    public var field: SyncedEvent.Field
    public var palmValue: String
    public var macValue: String
}

/// What one sync has to do, decided before anything is written: the Palm
/// side as records, the Mac side as shared-field values for the EventKit
/// adapter, and the mirror that is right once both have been applied.
public struct SyncPlan: Equatable, Sendable {
    public struct PalmWrite: Equatable, Sendable {
        /// nil: a new record, the Palm assigns the ID
        public var id: UInt32?
        public var category: Int
        public var record: Data
        /// index into `entries`, to take the assigned ID
        public var entry: Int
    }

    public struct MacChange: Equatable, Sendable {
        public var key: MacKey?
        public var event: SyncedEvent
        public var entry: Int
    }

    /// The mirror entries after this sync; the Palm ID or Mac key of a new
    /// item is filled in by `mirror(after:)`.
    public struct Entry: Equatable, Sendable {
        public var palmID: UInt32?
        public var mac: MacKey?
        public var event: SyncedEvent
        public var palmRecord: Data
        public var macOwned: Bool
    }

    public var palmWrites: [PalmWrite] = []
    public var palmDeletes: [UInt32] = []
    public var macCreates: [MacChange] = []
    public var macUpdates: [MacChange] = []
    public var macDeletes: [MacKey] = []
    public var conflicts: [SyncConflict] = []
    public var log: [String] = []
    public var entries: [Entry] = []
    /// Category names the Mac uses that the Palm's AppInfo lacks.
    public var missingCategories: [String] = []

    public var isEmpty: Bool {
        palmWrites.isEmpty && palmDeletes.isEmpty && macCreates.isEmpty && macUpdates.isEmpty && macDeletes.isEmpty
    }

    /// The mirror once the plan was applied: `palmIDs` maps the entry index
    /// of each new Palm record to the ID the Palm assigned, `macKeys` the
    /// entry index of each new Mac item to its key.
    public func mirror(after old: SyncMirror, palmIDs: [Int: UInt32], macKeys: [Int: MacKey], at date: Date = Date()) -> SyncMirror {
        var mirror = old
        mirror.lastSync = date
        mirror.entries = entries.enumerated().compactMap { i, e in
            guard let palmID = e.palmID ?? palmIDs[i], let mac = e.mac ?? macKeys[i] else { return nil }
            return MirrorEntry(palmID: palmID, mac: mac, base: e.event, palmRecord: e.palmRecord, macOwned: e.macOwned)
        }
        return mirror
    }
}

public enum SyncError: Error, Equatable {
    /// A fast sync needs a mirror from an earlier sync.
    case fastSyncWithoutMirror
}

/// Three-way merge of the Palm's Calendar against the Mac's, with the mirror
/// as the common ancestor. Rules:
///
/// - Only one side changed a field: that value wins. Both changed it to
///   different values: the `conflictPolicy` decides (Mac wins, Palm wins,
///   keep both), the losing value goes to the conflict log.
/// - Deleted on one side, unchanged on the other: deleted on both. Deleted
///   on one side, edited on the other: the edit wins and the item comes
///   back on the side that deleted it.
/// - Archived on the Palm: removed from the Palm's view, kept on the Mac.
/// - An item whose date left the window is dropped from the Palm and the
///   mirror, never from the Mac.
/// - An item the Mac owns (an expanded occurrence) takes no Palm edits:
///   they are logged and the record is rewritten from the Mac.
/// - Slow sync: Palm records unknown to the mirror are matched to Mac items
///   by date, time and title before either side gets a copy of the other's.
public struct CalendarSyncEngine {
    public var windowStart: PalmDate
    public var windowEnd: PalmDate
    public var conflictPolicy: ConflictPolicy

    public init(windowStart: PalmDate, windowEnd: PalmDate, conflictPolicy: ConflictPolicy = .macWins) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.conflictPolicy = conflictPolicy
    }

    public func plan(palm snapshot: PalmSnapshot, palmCategories: [String], mac items: [CalendarBuilder.MacItem],
                     mirror: SyncMirror) throws -> SyncPlan {
        var plan = SyncPlan()
        var categoryIndex: [String: Int] = [:]
        for (i, name) in palmCategories.enumerated() where !name.isEmpty { categoryIndex[name] = i }

        func palmCategory(_ name: String) -> Int {
            if let i = categoryIndex[name] { return i }
            if !plan.missingCategories.contains(name) { plan.missingCategories.append(name) }
            return 0
        }
        func palmEvent(_ record: PalmRecordIn) -> (SyncedEvent, CalendarEvent)? {
            guard let event = try? CalendarEvent(data: record.data) else {
                plan.log.append("Palm record \(record.id): cannot be decoded, left alone")
                return nil
            }
            let name = record.category < palmCategories.count ? palmCategories[record.category] : "Unfiled"
            return (SyncedEvent(event, category: name), event)
        }
        /// The bytes to write for `event` on top of an existing Palm record.
        func palmBytes(_ event: SyncedEvent, over existing: Data) -> Data {
            var record = (try? CalendarEvent(data: existing)) ?? CalendarEvent(date: event.date)
            event.apply(to: &record)
            return record.encode()
        }
        func writePalm(_ event: SyncedEvent, id: UInt32?, over existing: Data, mac: MacKey?, macOwned: Bool) {
            let bytes = palmBytes(event, over: existing)
            plan.entries.append(.init(palmID: id, mac: mac, event: event, palmRecord: bytes, macOwned: macOwned))
            plan.palmWrites.append(.init(id: id, category: palmCategory(event.category), record: bytes, entry: plan.entries.count - 1))
        }

        // What the Palm has now, by ID
        let fast: Bool
        var palmRecords: [UInt32: PalmRecordIn] = [:]
        switch snapshot {
        case .all(let records):
            fast = false
            for r in records { palmRecords[r.id] = r }
        case .modified(let records):
            guard mirror.lastSync != nil else { throw SyncError.fastSyncWithoutMirror }
            fast = true
            for r in records { palmRecords[r.id] = r }
        }
        var macItems: [MacKey: CalendarBuilder.MacItem] = [:]
        for item in items { macItems[item.key] = item }

        var usedPalm = Set<UInt32>()
        var usedMac = Set<MacKey>()

        // Items both sides know
        for entry in mirror.entries {
            usedPalm.insert(entry.palmID)
            usedMac.insert(entry.mac)
            let base = entry.base
            let current = palmRecords[entry.palmID]
            let item = macItems[entry.mac]

            // the Palm's state
            enum Side { case same, changed(SyncedEvent), deleted, archived }
            var palm: Side = .same
            var palmBytes = entry.palmRecord
            if let current {
                if current.isArchived { palm = .archived }
                else if current.isDeleted { palm = .deleted }
                else if let (event, _) = palmEvent(current) {
                    palmBytes = current.data
                    palm = event == base ? .same : .changed(event)
                }
            } else if !fast {
                palm = .deleted    // a slow sync lists every record: gone means deleted
            }

            // the Mac's state
            var mac: Side = .same
            var agedOut = false
            if let item {
                let event = SyncedEvent(item.event, category: item.category)
                mac = event == base ? .same : .changed(event)
            } else if base.date < windowStart || base.date > windowEnd {
                agedOut = true
            } else {
                mac = .deleted
            }

            if agedOut {
                if case .same = palm { plan.palmDeletes.append(entry.palmID) }
                if case .changed = palm { plan.palmDeletes.append(entry.palmID) }
                plan.log.append("\(base.title ?? "?"): left the window, removed from the Palm")
                continue
            }

            switch (palm, mac) {
            case (.same, .same):
                plan.entries.append(.init(palmID: entry.palmID, mac: entry.mac, event: base, palmRecord: palmBytes, macOwned: entry.macOwned))

            case (.archived, _):
                plan.log.append("\(base.title ?? "?"): archived on the Palm, kept on the Mac")
                // keep the Mac's version; the Palm forgets it

            case (.deleted, .same):
                plan.macDeletes.append(entry.mac)

            case (.deleted, .changed(let event)):
                plan.log.append("\(event.title ?? "?"): deleted on the Palm but edited on the Mac, put back on the Palm")
                writePalm(event, id: nil, over: entry.palmRecord, mac: entry.mac, macOwned: entry.macOwned)

            case (.same, .deleted):
                plan.palmDeletes.append(entry.palmID)

            case (.changed(let event), .deleted):
                if entry.macOwned {
                    plan.palmDeletes.append(entry.palmID)
                } else {
                    plan.log.append("\(event.title ?? "?"): deleted on the Mac but edited on the Palm, put back on the Mac")
                    plan.entries.append(.init(palmID: entry.palmID, mac: nil, event: event, palmRecord: palmBytes, macOwned: false))
                    plan.macCreates.append(.init(key: nil, event: event, entry: plan.entries.count - 1))
                }

            case (.changed(let event), .same):
                if entry.macOwned {
                    plan.log.append("\(base.title ?? "?"): edited on the Palm, but the Mac owns it; the edit is undone")
                    writePalm(base, id: entry.palmID, over: palmBytes, mac: entry.mac, macOwned: true)
                } else {
                    plan.entries.append(.init(palmID: entry.palmID, mac: entry.mac, event: event, palmRecord: palmBytes, macOwned: false))
                    plan.macUpdates.append(.init(key: entry.mac, event: event, entry: plan.entries.count - 1))
                }

            case (.same, .changed(let event)):
                writePalm(event, id: entry.palmID, over: palmBytes, mac: entry.mac, macOwned: entry.macOwned)

            case (.changed(let palmEvent), .changed(let macEvent)):
                if entry.macOwned {
                    plan.log.append("\(base.title ?? "?"): edited on the Palm, but the Mac owns it; the edit is undone")
                    writePalm(macEvent, id: entry.palmID, over: palmBytes, mac: entry.mac, macOwned: true)
                    break
                }
                let before = plan.conflicts.count
                let merged = Self.merge(base: base, palm: palmEvent, mac: macEvent, palmID: entry.palmID, mac: entry.mac,
                                        policy: conflictPolicy, conflicts: &plan.conflicts)
                if conflictPolicy == .keepBoth && plan.conflicts.count > before {
                    // the Palm's version lives on as a second item on both sides
                    plan.log.append("\(palmEvent.title ?? "?"): conflict, the Palm's version is kept as a second item")
                    writePalm(palmEvent, id: nil, over: palmBytes, mac: nil, macOwned: false)
                    plan.macCreates.append(.init(key: nil, event: palmEvent, entry: plan.entries.count - 1))
                }
                if merged != palmEvent {
                    writePalm(merged, id: entry.palmID, over: palmBytes, mac: entry.mac, macOwned: false)
                } else {
                    plan.entries.append(.init(palmID: entry.palmID, mac: entry.mac, event: merged, palmRecord: palmBytes, macOwned: false))
                }
                if merged != macEvent {
                    plan.macUpdates.append(.init(key: entry.mac, event: merged, entry: plan.entries.count - 1))
                }

            case (.deleted, .deleted), (.deleted, .archived), (.same, .archived), (.changed, .archived):
                break    // gone on both sides, or the Mac side cannot be archived
            }
        }

        // New on the Palm
        var newPalm = palmRecords.values.filter { !usedPalm.contains($0.id) && !$0.isDeleted && !$0.isArchived }
            .sorted { $0.id < $1.id }
        var newMac = items.filter { !usedMac.contains($0.key) }

        if !fast {
            // slow sync: the same event on both sides is one item
            var remaining: [CalendarBuilder.MacItem] = []
            for item in newMac {
                let candidate = SyncedEvent(item.event, category: item.category)
                if let i = newPalm.firstIndex(where: { record in
                    guard let (event, _) = palmEvent(record) else { return false }
                    return event.date == candidate.date && event.time == candidate.time && event.title == candidate.title
                }) {
                    let record = newPalm.remove(at: i)
                    let (palmVersion, _) = palmEvent(record)!
                    // no common ancestor: the Palm's version stands in for it,
                    // so every difference is a Mac change
                    let merged = Self.merge(base: palmVersion, palm: palmVersion, mac: candidate, palmID: record.id, mac: item.key,
                                            policy: conflictPolicy, conflicts: &plan.conflicts)
                    if merged != palmVersion {
                        writePalm(merged, id: record.id, over: record.data, mac: item.key, macOwned: item.macOwned)
                    } else {
                        plan.entries.append(.init(palmID: record.id, mac: item.key, event: merged, palmRecord: record.data, macOwned: item.macOwned))
                    }
                    plan.log.append("\(candidate.title ?? "?"): found on both sides, paired")
                } else {
                    remaining.append(item)
                }
            }
            newMac = remaining
        }

        for record in newPalm {
            guard let (event, _) = palmEvent(record) else { continue }
            plan.entries.append(.init(palmID: record.id, mac: nil, event: event, palmRecord: record.data, macOwned: false))
            plan.macCreates.append(.init(key: nil, event: event, entry: plan.entries.count - 1))
        }
        for item in newMac {
            let event = SyncedEvent(item.event, category: item.category)
            writePalm(event, id: nil, over: item.event.encode(), mac: item.key, macOwned: item.macOwned)
        }

        return plan
    }

    /// Field by field against the base; a field both changed goes to the
    /// policy's side (keep both: the Mac's, the caller duplicates the item).
    static func merge(base: SyncedEvent, palm: SyncedEvent, mac: SyncedEvent, palmID: UInt32?, mac key: MacKey?,
                      policy: ConflictPolicy = .macWins, conflicts: inout [SyncConflict]) -> SyncedEvent {
        var merged = base
        for field in SyncedEvent.Field.allCases {
            let palmChanged = palm.differs(from: base, in: field)
            let macChanged = mac.differs(from: base, in: field)
            switch (palmChanged, macChanged) {
            case (false, false): break
            case (true, false): merged.set(field, from: palm)
            case (false, true): merged.set(field, from: mac)
            case (true, true):
                merged.set(field, from: policy == .palmWins ? palm : mac)
                if palm.differs(from: mac, in: field) {
                    conflicts.append(SyncConflict(palmID: palmID, mac: key, title: mac.title ?? palm.title ?? "",
                                                  field: field, palmValue: palm.describe(field), macValue: mac.describe(field)))
                }
            }
        }
        return merged
    }
}
