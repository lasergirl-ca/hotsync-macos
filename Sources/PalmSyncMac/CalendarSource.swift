import EventKit
import Foundation
import PalmSync

/// Calendar.app through EventKit, as the sync sees it: the calendars to
/// choose from and the events of a window as MacEvents. One instance per
/// process: the event store keeps the access grant.
public final class CalendarSource: @unchecked Sendable {
    public struct Calendar: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        /// "iCloud", the Gmail address, "Subscribed Calendars", …
        public let source: String
        public let isSubscribed: Bool
        public let isReadOnly: Bool

        public init(id: String, title: String, source: String, isSubscribed: Bool, isReadOnly: Bool) {
            self.id = id
            self.title = title
            self.source = source
            self.isSubscribed = isSubscribed
            self.isReadOnly = isReadOnly
        }
    }

    public let store = EKEventStore()

    public init() {}

    public var accessStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    public var hasAccess: Bool { accessStatus == .fullAccess }

    /// Asks macOS for full access (the prompt appears once); false if denied.
    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func calendars() -> [Calendar] {
        store.calendars(for: .event)
            .map { Calendar(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                            isSubscribed: $0.isSubscribed, isReadOnly: !$0.allowsContentModifications) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// Every occurrence in the window from the given calendars; calendars
    /// that no longer exist are skipped.
    public func events(from start: Date, to end: Date, calendarIDs: [String]) -> [MacEvent] {
        let calendars = calendarIDs.compactMap { store.calendar(withIdentifier: $0) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).map(Self.macEvent)
    }

    // MARK: EventKit to MacEvent

    public static func macEvent(_ e: EKEvent) -> MacEvent {
        MacEvent(
            externalID: e.calendarItemExternalIdentifier,
            seriesID: e.calendarItemIdentifier,
            calendarID: e.calendar.calendarIdentifier,
            title: e.title ?? "",
            notes: e.notes,
            location: e.location,
            url: e.url,
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            alarmOffset: e.alarms?.map(\.relativeOffset).min(),
            recurrence: e.hasRecurrenceRules ? macRecurrence(e.recurrenceRules ?? []) : nil,
            occurrenceDate: e.occurrenceDate,
            isDetached: e.isDetached)
    }

    public static func macRecurrence(_ rules: [EKRecurrenceRule]) -> MacRecurrence? {
        guard let rule = rules.first else { return nil }
        // several rules, or a frequency EventKit added later: nothing the Palm
        // could express, so make sure the series is expanded
        let unsupported = MacRecurrence(frequency: .daily, setPositions: [0])
        guard rules.count == 1 else { return unsupported }
        let frequency: MacRecurrence.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return unsupported
        }
        var end: MacRecurrence.End?
        if let e = rule.recurrenceEnd {
            if let date = e.endDate { end = .date(date) } else { end = .count(e.occurrenceCount) }
        }
        return MacRecurrence(
            frequency: frequency,
            interval: rule.interval,
            daysOfTheWeek: (rule.daysOfTheWeek ?? []).map { .init($0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber) },
            daysOfTheMonth: (rule.daysOfTheMonth ?? []).map(\.intValue),
            monthsOfTheYear: (rule.monthsOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            end: end,
            firstDayOfTheWeek: rule.firstDayOfTheWeek)
    }
}

/// What the user chose for a Palm: which calendars, under which category,
/// and how far back and ahead. Stored with the device profile.
public struct CalendarSyncSettings: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        /// nil: the calendar's title
        public var category: String?

        public init(id: String, title: String, category: String? = nil) {
            self.id = id
            self.title = title
            self.category = category
        }
    }

    public var enabled: Bool
    public var calendars: [Choice]
    public var daysBack: Int
    public var daysAhead: Int
    /// nil (profiles from before the setting): the Mac wins
    public var conflictPolicy: ConflictPolicy?

    public init(enabled: Bool = false, calendars: [Choice] = [], daysBack: Int = 90, daysAhead: Int = 365,
                conflictPolicy: ConflictPolicy? = nil) {
        self.enabled = enabled
        self.calendars = calendars
        self.daysBack = daysBack
        self.daysAhead = daysAhead
        self.conflictPolicy = conflictPolicy
    }

    public var conflicts: ConflictPolicy { conflictPolicy ?? .macWins }

    public var macCalendars: [CalendarBuilder.MacCalendar] {
        calendars.map { .init(id: $0.id, title: $0.title, category: $0.category?.isEmpty == false ? $0.category : nil) }
    }
}

/// One run of the one-way calendar sync: the window, the events, the
/// database, checked by reading it back.
public struct CalendarSyncRun {
    public let windowStart: Date
    public let windowEnd: Date
    public let occurrences: Int
    public let database: PalmDatabase
    public let report: CalendarBuilder.Report

    public enum Failure: Error {
        case noAccess
        case doesNotReadBack
    }

    public init(settings: CalendarSyncSettings, source: CalendarSource, homeZone: TimeZone = .current, now: Date = Date()) throws {
        guard source.hasAccess else { throw Failure.noAccess }
        let calendar = Foundation.Calendar.current
        let today = calendar.startOfDay(for: now)
        windowStart = calendar.date(byAdding: .day, value: -settings.daysBack, to: today)!
        windowEnd = calendar.date(byAdding: .day, value: settings.daysAhead, to: today)!
        let events = source.events(from: windowStart, to: windowEnd, calendarIDs: settings.calendars.map(\.id))
        occurrences = events.count
        let builder = CalendarBuilder(options: .init(
            homeZone: homeZone, windowStart: windowStart, windowEnd: windowEnd, calendars: settings.macCalendars,
            startOfWeek: calendar.firstWeekday == 2 ? 1 : 0))
        (database, report) = builder.build(events)

        // what was built must read back as it was meant, before it goes near a Palm
        let image = database.encode()
        guard let check = try? PalmDatabase(data: image), check == database,
              check.records.allSatisfy({ (try? CalendarEvent(data: $0.data))?.encode() == $0.data }),
              let appInfo = check.appInfo, (try? CalendarAppInfo(data: appInfo)) != nil else {
            throw Failure.doesNotReadBack
        }
    }

    /// Writes the database where the install queue picks it up.
    @discardableResult
    public func write(to url: URL) throws -> Int {
        let image = database.encode()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try image.write(to: url, options: .atomic)
        return image.count
    }
}
