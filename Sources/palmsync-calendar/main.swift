// palmsync-calendar: the Mac side of the one-way calendar sync (Phase 2).
// Reads the chosen Calendar.app calendars through EventKit for a window of
// days and writes a CalendarDB-PDat.pdb into a device's Install/ folder;
// the next HotSync installs it and the Palm's Calendar shows the Mac's.
//
//   palmsync-calendar --list
//   palmsync-calendar --calendar Work --calendar "Family=iC Family" --device "Zoë Leto" [--back 90] [--ahead 365]
//   palmsync-calendar --calendar Work --out /tmp/CalendarDB-PDat.pdb
//   palmsync-calendar --calendar Work --dry-run
//
// --calendar takes a calendar title (or identifier from --list), with an
// optional "=Category" naming the Palm category; calendars listed first
// win when the same invite is in several. The Palm's copy of the database
// is replaced whole: edits made on the Palm are lost. Phase 3 changes that.

import EventKit
import Foundation
import PalmSync

struct Arguments {
    var list = false
    var dryRun = false
    var calendars: [(name: String, category: String?)] = []
    var device: String?
    var out: String?
    var back = 90
    var ahead = 365

    init(_ args: [String]) throws {
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw Usage("\(flag) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--list": list = true
            case "--dry-run": dryRun = true
            case "--calendar":
                let spec = try value("--calendar")
                if let eq = spec.firstIndex(of: "=") {
                    calendars.append((String(spec[..<eq]), String(spec[spec.index(after: eq)...])))
                } else {
                    calendars.append((spec, nil))
                }
            case "--device": device = try value("--device")
            case "--out": out = try value("--out")
            case "--back": back = Int(try value("--back")) ?? -1
            case "--ahead": ahead = Int(try value("--ahead")) ?? -1
            case "-h", "--help": throw Usage(nil)
            default: throw Usage("unknown option \(args[i])")
            }
            i += 1
        }
        guard back >= 0, ahead >= 0 else { throw Usage("--back and --ahead take a number of days") }
        if !list && calendars.isEmpty { throw Usage("choose calendars with --calendar (see --list)") }
        if !list && !dryRun && device == nil && out == nil {
            throw Usage("say where the database goes: --device NAME or --out PATH (or --dry-run)")
        }
    }

    var outputURL: URL? {
        if let out { return URL(fileURLWithPath: out) }
        guard let device else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("HotSync").appendingPathComponent(device)
            .appendingPathComponent("Install").appendingPathComponent("CalendarDB-PDat.pdb")
    }
}

struct Usage: Error {
    let message: String?
    init(_ message: String?) { self.message = message }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("palmsync-calendar: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - EventKit to MacEvent

func macRecurrence(_ rules: [EKRecurrenceRule]) -> MacRecurrence? {
    guard let rule = rules.first else { return nil }
    guard rules.count == 1 else {
        // several rules: nothing the Palm could express, so make sure it is expanded
        return MacRecurrence(frequency: .daily, setPositions: [0])
    }
    let frequency: MacRecurrence.Frequency
    switch rule.frequency {
    case .daily: frequency = .daily
    case .weekly: frequency = .weekly
    case .monthly: frequency = .monthly
    case .yearly: frequency = .yearly
    @unknown default: return MacRecurrence(frequency: .daily, setPositions: [0])
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

func macEvent(_ e: EKEvent) -> MacEvent {
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

func describe(_ rule: CalendarEvent.Repeat, exceptions: Int) -> String {
    var text = " (repeats "
    switch rule.type {
    case .daily: text += rule.frequency == 1 ? "daily" : "every \(rule.frequency) days"
    case .weekly:
        let names = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
        let days = (0..<7).filter { rule.weekdays.rawValue & (1 << $0) != 0 }.map { names[$0] }
        text += (rule.frequency == 1 ? "weekly" : "every \(rule.frequency) weeks") + " on " + days.joined(separator: " ")
    case .monthlyByDate: text += rule.frequency == 1 ? "monthly" : "every \(rule.frequency) months"
    case .monthlyByDay:
        let week = ["1st", "2nd", "3rd", "4th", "last"][min(4, Int(rule.on) / 7)]
        let day = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][Int(rule.on) % 7]
        text += "monthly on the \(week) \(day)"
    case .yearly: text += rule.frequency == 1 ? "yearly" : "every \(rule.frequency) years"
    }
    if let end = rule.endDate { text += String(format: " until %d-%02d-%02d", end.year, end.month, end.day) }
    if exceptions > 0 { text += ", \(exceptions) exception\(exceptions == 1 ? "" : "s")" }
    return text + ")"
}

// MARK: - Main

let arguments: Arguments
do {
    arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
} catch let usage as Usage {
    if let message = usage.message { FileHandle.standardError.write("palmsync-calendar: \(message)\n".data(using: .utf8)!) }
    print("""
    usage: palmsync-calendar --list
           palmsync-calendar --calendar NAME[=Category] ... (--device NAME | --out PATH | --dry-run) [--back DAYS] [--ahead DAYS]
    """)
    exit(usage.message == nil ? 0 : 2)
}

let store = EKEventStore()
let granted = try await store.requestFullAccessToEvents()
guard granted else {
    let status: String
    switch EKEventStore.authorizationStatus(for: .event) {
    case .notDetermined: status = "not determined (macOS showed no prompt)"
    case .denied: status = "denied"
    case .restricted: status = "restricted"
    case .writeOnly: status = "add-only; full access is needed"
    case .fullAccess: status = "full access, yet the request failed"
    @unknown default: status = "unknown"
    }
    fail("no access to Calendar (\(status)): allow it in System Settings > Privacy & Security > Calendars")
}

let all = store.calendars(for: .event)

if arguments.list {
    for source in Set(all.map(\.source)).sorted(by: { $0.title < $1.title }) {
        print("\(source.title):")
        for cal in all.filter({ $0.source == source }).sorted(by: { $0.title < $1.title }) {
            let kind = cal.isSubscribed ? "subscribed" : (cal.allowsContentModifications ? "" : "read-only")
            print("  \(cal.title.padding(toLength: 28, withPad: " ", startingAt: 0)) \(cal.calendarIdentifier) \(kind)")
        }
    }
    exit(0)
}

var chosen: [CalendarBuilder.MacCalendar] = []
var ekCalendars: [EKCalendar] = []
for spec in arguments.calendars {
    let matches = all.filter { $0.calendarIdentifier == spec.name || $0.title == spec.name }
    guard !matches.isEmpty else { fail("no calendar named \"\(spec.name)\" (see --list)") }
    guard matches.count == 1 else {
        fail("\"\(spec.name)\" names \(matches.count) calendars; use the identifier from --list: "
             + matches.map { "\($0.calendarIdentifier) (\($0.source.title))" }.joined(separator: ", "))
    }
    chosen.append(.init(id: matches[0].calendarIdentifier, title: matches[0].title, category: spec.category))
    ekCalendars.append(matches[0])
}

let now = Date()
let windowStart = Calendar.current.date(byAdding: .day, value: -arguments.back, to: Calendar.current.startOfDay(for: now))!
let windowEnd = Calendar.current.date(byAdding: .day, value: arguments.ahead, to: Calendar.current.startOfDay(for: now))!
let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: ekCalendars)
let events = store.events(matching: predicate).map(macEvent)

let builder = CalendarBuilder(options: .init(
    homeZone: .current, windowStart: windowStart, windowEnd: windowEnd, calendars: chosen,
    startOfWeek: Calendar.current.firstWeekday == 2 ? 1 : 0))
let (database, report) = builder.build(events)

let tzdata = (try? String(contentsOfFile: "/usr/share/zoneinfo/+VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
let dayFormat = DateFormatter()
dayFormat.dateFormat = "yyyy-MM-dd"
print("window:     \(dayFormat.string(from: windowStart)) to \(dayFormat.string(from: windowEnd)), home zone \(TimeZone.current.identifier), tzdata \(tzdata)")
print("calendars:  \(chosen.map(\.title).joined(separator: ", "))")
print("categories: \(report.categories.joined(separator: ", "))")
print("records:    \(report.records) (\(events.count) occurrences on the Mac: \(report.seriesMapped) series as repeat rules with \(report.exceptions) exceptions, \(report.seriesExpanded) series expanded, \(report.detachedOccurrences) edited occurrences, \(report.duplicatesDropped) duplicates dropped)")
for warning in report.warnings { print("warning:    \(warning)") }

if arguments.dryRun {
    print("")
    for record in database.records.prefix(40) {
        let event = try CalendarEvent(data: record.data)
        let time = event.time.map { String(format: "%02d:%02d-%02d:%02d", $0.start.hour, $0.start.minute, $0.end.hour, $0.end.minute) } ?? "all day    "
        let rule = event.repeatRule.map { describe($0, exceptions: event.exceptions.count) } ?? ""
        print("  \(event.date.year)-\(String(format: "%02d-%02d", event.date.month, event.date.day)) \(time)  [\(report.categories[record.category])] \(event.title ?? "")\(rule)")
    }
    if database.records.count > 40 { print("  … \(database.records.count - 40) more") }
    exit(0)
}

// what was built must read back as it was meant, before it goes anywhere near a Palm
let image = database.encode()
let check = try PalmDatabase(data: image)
guard check == database, check.records.count == report.records else { fail("the built database does not read back as built") }
for record in check.records {
    guard let event = try? CalendarEvent(data: record.data), event.encode() == record.data else {
        fail("record \(record.uniqueID) does not decode as written")
    }
}
_ = try CalendarAppInfo(data: check.appInfo!)

let url = arguments.outputURL!
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try image.write(to: url, options: .atomic)
print("wrote:      \(url.path) (\(image.count) bytes, verified)")
