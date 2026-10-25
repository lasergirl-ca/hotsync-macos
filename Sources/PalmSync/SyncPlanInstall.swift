import Foundation

extension SyncPlan {
    /// The Palm's side of the plan as a whole database to install: every
    /// entry's record, new ones with IDs this Mac assigns, categories from
    /// the Palm's own block plus any the Mac brought along, sorted by date
    /// and time as the Calendar expects. Replacing the database whole
    /// instead of writing records keeps the Palm's record order sane and
    /// resets its modified flags, so the next sync can be a fast one.
    ///
    /// Returns the database and, per entry index, the ID a new record got,
    /// for `mirror(after:palmIDs:macKeys:)`.
    public func palmDatabase(categories existing: CategoryAppInfo, startOfWeek: UInt8 = 0)
        -> (database: PalmDatabase, palmIDs: [Int: UInt32], categories: CategoryAppInfo) {
        var categories = existing
        func index(of name: String) -> Int {
            if let i = categories.names.firstIndex(of: name) { return i }
            if let free = categories.names.indices.dropFirst().first(where: { categories.names[$0].isEmpty }) {
                categories.names[free] = String(name.prefix(CategoryAppInfo.nameWidth - 1))
                return free
            }
            return 0
        }

        var nextID = (entries.compactMap(\.palmID).max() ?? 0) + 1
        var palmIDs: [Int: UInt32] = [:]
        var records: [(date: PalmDate, time: PalmTime?, record: PalmDatabase.Record)] = []
        for (i, entry) in entries.enumerated() {
            let id: UInt32
            if let known = entry.palmID {
                id = known
            } else {
                id = nextID
                nextID += 1
                palmIDs[i] = id
            }
            records.append((entry.event.date, entry.event.time?.start,
                            PalmDatabase.Record(category: index(of: entry.event.category), uniqueID: id, data: entry.palmRecord)))
        }
        records.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            switch (a.time, b.time) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x < y
            }
        }

        var db = PalmDatabase(name: CalendarBuilder.databaseName, type: "DATA", creator: "PDat", attributes: 0, version: 1,
                              appInfo: CalendarAppInfo(categories: categories, startOfWeek: startOfWeek).encode())
        db.records = records.map(\.record)
        db.uniqueIDSeed = nextID
        return (db, palmIDs, categories)
    }
}
