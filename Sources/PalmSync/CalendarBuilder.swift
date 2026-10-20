import Foundation

/// Builds a complete CalendarDB-PDat from the Mac's events for one window:
/// the Phase 2 one-way sync, where the database is installed whole and the
/// Palm's copy is replaced. Every decision about what the Palm can and
/// cannot represent lives here; the result says what it did.
///
/// - Times are converted into the home zone and written without a time
///   zone, so the Palm's own DST rules never touch them.
/// - A series whose rule the Palm can express becomes one repeating record;
///   generated dates that have no occurrence on the Mac become exceptions,
///   occurrences edited on their own become exceptions plus a record of
///   their own.
/// - A series the Palm cannot express is expanded into one record per
///   occurrence inside the window.
/// - Each Mac calendar maps to a Palm category; past 15 they fold into
///   "Other".
public struct CalendarBuilder {
    public struct Options: Sendable {
        /// The zone the Palm's clock runs in.
        public var homeZone: TimeZone
        public var windowStart: Date
        public var windowEnd: Date
        /// Mac calendars in priority order; an invite that is in several
        /// calendars (same externalID) is kept from the first.
        public var calendars: [MacCalendar]
        /// 0 = Sunday, 1 = Monday, for the AppInfo and weekly rules without one.
        public var startOfWeek: UInt8

        public init(homeZone: TimeZone = .current, windowStart: Date, windowEnd: Date,
                    calendars: [MacCalendar], startOfWeek: UInt8 = 0) {
            self.homeZone = homeZone
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.calendars = calendars
            self.startOfWeek = startOfWeek
        }
    }

    public struct MacCalendar: Equatable, Sendable {
        public var id: String
        public var title: String
        /// The Palm category this calendar's events get; several calendars
        /// may share one. nil: the calendar's own title.
        public var category: String?

        public init(id: String, title: String, category: String? = nil) {
            self.id = id
            self.title = title
            self.category = category
        }
    }

    public struct Report: Equatable, Sendable {
        public var records = 0
        public var seriesMapped = 0
        public var seriesExpanded = 0
        public var detachedOccurrences = 0
        public var exceptions = 0
        public var duplicatesDropped = 0
        public var categories: [String] = []
        public var warnings: [String] = []
    }

    public static let databaseName = "CalendarDB-PDat"
    public static let maxCategories = 16   // including Unfiled
    public static let overflowCategory = "Other"

    public let options: Options
    private let calendar: Calendar

    public init(options: Options) {
        self.options = options
        var c = Calendar(identifier: .gregorian)
        c.timeZone = options.homeZone
        calendar = c
    }

    // MARK: Building

    public func build(_ events: [MacEvent]) -> (database: PalmDatabase, report: Report) {
        var report = Report()
        let (categories, categoryOf) = assignCategories(&report)
        let kept = dropDuplicates(events, &report)

        var records: [(date: PalmDate, time: PalmTime?, event: CalendarEvent, category: Int)] = []
        func add(_ event: CalendarEvent, category: Int) {
            records.append((event.date, event.time?.start, event, category))
        }

        // group the occurrences of each series, keep the order of first appearance
        var seriesOrder: [String] = []
        var series: [String: [MacEvent]] = [:]
        for event in kept {
            if series[event.seriesID] == nil { seriesOrder.append(event.seriesID) }
            series[event.seriesID, default: []].append(event)
        }

        for id in seriesOrder {
            let occurrences = series[id]!.sorted { $0.start < $1.start }
            let category = categoryOf[occurrences[0].calendarID] ?? 0

            guard let rule = occurrences[0].recurrence else {
                for occurrence in occurrences { add(convert(occurrence), category: category) }
                continue
            }

            let regular = occurrences.filter { !$0.isDetached }
            let detached = occurrences.filter(\.isDetached)
            guard let master = regular.first, let palmRule = palmRule(rule, start: master.start) else {
                // the Palm cannot express this rule (or every occurrence in
                // the window was edited): one record per occurrence
                report.seriesExpanded += 1
                for occurrence in occurrences { add(convert(occurrence), category: category) }
                continue
            }

            var record = convert(master)
            record.repeatRule = palmRule
            let generated = PalmRecurrence.occurrences(of: palmRule, startingOn: record.date,
                                                       through: PalmDate(options.windowEnd, in: calendar))
            let present = Set(regular.map { PalmDate($0.occurrenceDate ?? $0.start, in: calendar) })
            var exceptions = generated.filter { !present.contains($0) }
            for occurrence in detached {
                // the day the rule put the occurrence on, before it was edited
                let original = PalmDate(occurrence.occurrenceDate ?? occurrence.start, in: calendar)
                if !exceptions.contains(original) { exceptions.append(original) }
                add(convert(occurrence), category: category)
                report.detachedOccurrences += 1
            }
            record.exceptions = exceptions.sorted()
            report.exceptions += exceptions.count
            report.seriesMapped += 1
            add(record, category: category)
        }

        // the Datebook expects its records sorted by date and time
        records.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            switch (a.time, b.time) {
            case (nil, nil): return false
            case (nil, _): return true      // timeless first
            case (_, nil): return false
            case let (x?, y?): return x < y
            }
        }

        var db = PalmDatabase(name: Self.databaseName, type: "DATA", creator: "PDat",
                              appInfo: CalendarAppInfo(categories: categories, startOfWeek: options.startOfWeek).encode())
        db.records = records.enumerated().map { i, r in
            PalmDatabase.Record(category: r.category, uniqueID: UInt32(i + 1), data: r.event.encode())
        }
        db.uniqueIDSeed = UInt32(records.count + 1)
        report.records = records.count
        report.categories = categories.named.map(\.name)
        return (db, report)
    }

    // MARK: Categories

    private func assignCategories(_ report: inout Report) -> (CategoryAppInfo, [String: Int]) {
        var names = ["Unfiled"]
        var categoryOf: [String: Int] = [:]
        var overflow = false
        for cal in options.calendars {
            let name = String((cal.category ?? cal.title).prefix(CategoryAppInfo.nameWidth - 1))
            if let index = names.firstIndex(of: name) {
                categoryOf[cal.id] = index
            } else if names.count < Self.maxCategories - 1
                        || (names.count == Self.maxCategories - 1 && !overflowNeeded(after: cal)) {
                names.append(name)
                categoryOf[cal.id] = names.count - 1
            } else {
                if !overflow {
                    names.append(Self.overflowCategory)
                    overflow = true
                    report.warnings.append("more than \(Self.maxCategories - 1) categories: the rest go into \"\(Self.overflowCategory)\"")
                }
                categoryOf[cal.id] = names.firstIndex(of: Self.overflowCategory)!
            }
        }
        return (CategoryAppInfo(names: names), categoryOf)
    }

    /// Whether calendars after this one still need a category of their own
    /// (so the last free slot can be kept for "Other").
    private func overflowNeeded(after cal: MacCalendar) -> Bool {
        guard let i = options.calendars.firstIndex(of: cal) else { return false }
        let used = Set(options.calendars[...i].map { $0.category ?? $0.title })
        return options.calendars[(i + 1)...].contains { !used.contains($0.category ?? $0.title) }
    }

    // MARK: Duplicates

    private func dropDuplicates(_ events: [MacEvent], _ report: inout Report) -> [MacEvent] {
        let priority = Dictionary(uniqueKeysWithValues: options.calendars.enumerated().map { ($1.id, $0) })
        // the calendar that owns each externalID: the one with the best priority
        var owner: [String: String] = [:]
        for event in events {
            guard let key = event.externalID else { continue }
            let rank = priority[event.calendarID] ?? Int.max
            if let current = owner[key], (priority[current] ?? Int.max) <= rank { continue }
            owner[key] = event.calendarID
        }
        return events.filter { event in
            guard let key = event.externalID, let ownerID = owner[key] else { return true }
            if ownerID == event.calendarID { return true }
            report.duplicatesDropped += 1
            return false
        }
    }

    // MARK: One event

    /// The Palm record for one occurrence, without the repeat rule.
    func convert(_ event: MacEvent) -> CalendarEvent {
        let date = PalmDate(event.start, in: calendar)
        var record = CalendarEvent(date: date)

        if event.isAllDay {
            record.time = nil
        } else {
            let start = calendar.dateComponents([.hour, .minute], from: event.start)
            var end = calendar.dateComponents([.hour, .minute], from: event.end)
            if PalmDate(event.end, in: calendar) > date {
                // the Palm cannot span midnight: the record ends at the end of its day
                end = DateComponents(hour: 23, minute: 59)
            }
            record.time = .init(start: PalmTime(hour: start.hour!, minute: start.minute!),
                                end: PalmTime(hour: end.hour!, minute: end.minute!))
        }

        record.title = event.title
        var note = event.notes ?? ""
        if let url = event.url {
            note += note.isEmpty ? url.absoluteString : "\n\(url.absoluteString)"
        }
        record.note = note.isEmpty ? nil : note
        record.location = (event.location?.isEmpty == false) ? event.location : nil
        record.alarm = event.alarmOffset.flatMap(alarm)
        return record
    }

    /// The Palm counts minutes, hours or days before the start, up to 99 of
    /// each; an alarm after the start, or further away, is dropped.
    func alarm(for offset: TimeInterval) -> CalendarEvent.Alarm? {
        guard offset <= 0 else { return nil }
        let minutes = Int(-offset / 60)
        if minutes % 1440 == 0, minutes / 1440 <= 99 {
            return .init(advance: UInt8(minutes / 1440), unit: .days)
        }
        if minutes % 60 == 0, minutes / 60 <= 99 {
            return .init(advance: UInt8(minutes / 60), unit: .hours)
        }
        if minutes <= 99 {
            return .init(advance: UInt8(minutes), unit: .minutes)
        }
        if minutes / 60 <= 99 { return .init(advance: UInt8(minutes / 60), unit: .hours) }
        if minutes / 1440 <= 99 { return .init(advance: UInt8(minutes / 1440), unit: .days) }
        return nil
    }

    /// The Palm rule for a Mac rule, nil when the Palm cannot express it:
    /// counted ends, set positions, month lists, several weekdays with a
    /// week number, and the like.
    func palmRule(_ rule: MacRecurrence, start: Date) -> CalendarEvent.Repeat? {
        guard (1...255).contains(rule.interval), rule.setPositions.isEmpty, rule.monthsOfTheYear.isEmpty else {
            return nil
        }
        var endDate: PalmDate?
        switch rule.end {
        case nil: endDate = nil
        case .date(let date): endDate = PalmDate(date, in: calendar)
        case .count: return nil
        }
        let startDate = PalmDate(start, in: calendar)
        let frequency = UInt8(rule.interval)
        let weekStart: UInt8 = rule.firstDayOfTheWeek == 2 ? 1 : (rule.firstDayOfTheWeek == 1 ? 0 : options.startOfWeek)

        switch rule.frequency {
        case .daily:
            guard rule.daysOfTheWeek.isEmpty, rule.daysOfTheMonth.isEmpty else { return nil }
            return .init(type: .daily, endDate: endDate, frequency: frequency)

        case .weekly:
            guard rule.daysOfTheMonth.isEmpty, rule.daysOfTheWeek.allSatisfy({ $0.weekNumber == 0 }) else { return nil }
            var mask: UInt8 = 0
            for day in rule.daysOfTheWeek { mask |= 1 << UInt8(day.weekday - 1) }
            if mask == 0 { mask = 1 << UInt8(startDate.weekday) }
            return .init(type: .weekly, endDate: endDate, frequency: frequency, on: mask, weekStart: weekStart)

        case .monthly:
            if rule.daysOfTheWeek.isEmpty {
                guard rule.daysOfTheMonth.isEmpty || rule.daysOfTheMonth == [startDate.day] else { return nil }
                return .init(type: .monthlyByDate, endDate: endDate, frequency: frequency)
            }
            guard rule.daysOfTheMonth.isEmpty, rule.daysOfTheWeek.count == 1 else { return nil }
            let day = rule.daysOfTheWeek[0]
            let week: Int
            switch day.weekNumber {
            case 1...4: week = day.weekNumber - 1
            case -1: week = 4
            default: return nil
            }
            return .init(type: .monthlyByDay, endDate: endDate, frequency: frequency,
                         on: UInt8(week * 7 + day.weekday - 1))

        case .yearly:
            guard rule.daysOfTheWeek.isEmpty, rule.daysOfTheMonth.isEmpty else { return nil }
            return .init(type: .yearly, endDate: endDate, frequency: frequency)
        }
    }
}
