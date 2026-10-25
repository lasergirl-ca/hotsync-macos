import EventKit
import Foundation
import Testing
import PalmSync
@testable import PalmSyncMac

// The mapping only: EKEvents are made and filled, never saved, so no
// Calendar access is needed.
private let store = EKEventStore()
private let vancouver: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Vancouver")!
    return c
}()

@Test func timedEventFields() {
    let event = SyncedEvent(date: PalmDate(year: 2026, month: 10, day: 20),
                            time: .init(start: PalmTime(hour: 9, minute: 0), end: PalmTime(hour: 10, minute: 30)),
                            title: "Standup", note: "bring coffee", location: "Room 4",
                            alarm: .init(advance: 15, unit: .minutes), category: "Work")
    let ek = EKEvent(eventStore: store)
    CalendarWriter.fill(ek, from: event, in: vancouver)
    #expect(ek.title == "Standup" && ek.notes == "bring coffee" && ek.location == "Room 4")
    #expect(!ek.isAllDay)
    #expect(vancouver.dateComponents([.hour, .minute], from: ek.startDate).hour == 9)
    #expect(ek.endDate.timeIntervalSince(ek.startDate) == 90 * 60)
    #expect(ek.alarms?.first?.relativeOffset == -900)
    #expect(ek.timeZone?.identifier == "America/Vancouver")
    #expect(ek.recurrenceRules?.isEmpty ?? true)
}

@Test func allDayEvent() {
    let event = SyncedEvent(date: PalmDate(year: 2026, month: 11, day: 1), title: "Clocks stay", category: "Personal")
    let ek = EKEvent(eventStore: store)
    CalendarWriter.fill(ek, from: event, in: vancouver)
    #expect(ek.isAllDay)
    #expect(vancouver.component(.day, from: ek.startDate) == 1 && vancouver.component(.day, from: ek.endDate) == 1)
    #expect(ek.alarms == nil || ek.alarms?.isEmpty == true)
}

@Test func rulesBecomeRecurrenceRules() {
    let start = PalmDate(year: 2026, month: 10, day: 19)   // a Monday
    var weekly = CalendarEvent.Repeat(type: .weekly, endDate: PalmDate(year: 2026, month: 11, day: 30), frequency: 2)
    weekly.weekdays = [.monday, .wednesday]
    let w = CalendarWriter.recurrenceRule(weekly, start: start, in: vancouver)
    #expect(w.frequency == .weekly && w.interval == 2)
    #expect(w.daysOfTheWeek?.map(\.dayOfTheWeek.rawValue) == [2, 4])
    #expect(w.recurrenceEnd?.endDate.map { vancouver.component(.day, from: $0) } == 30)

    let byDate = CalendarWriter.recurrenceRule(.init(type: .monthlyByDate, frequency: 1), start: start, in: vancouver)
    #expect(byDate.frequency == .monthly && byDate.daysOfTheMonth?.first?.intValue == 19)

    let secondTuesday = CalendarWriter.recurrenceRule(.init(type: .monthlyByDay, frequency: 1, on: 9), start: start, in: vancouver)
    #expect(secondTuesday.daysOfTheWeek?.first?.dayOfTheWeek == .tuesday && secondTuesday.daysOfTheWeek?.first?.weekNumber == 2)
    let lastFriday = CalendarWriter.recurrenceRule(.init(type: .monthlyByDay, frequency: 1, on: 33), start: start, in: vancouver)
    #expect(lastFriday.daysOfTheWeek?.first?.weekNumber == -1)

    let yearly = CalendarWriter.recurrenceRule(.init(type: .yearly, frequency: 1), start: start, in: vancouver)
    #expect(yearly.frequency == .yearly && yearly.recurrenceEnd == nil)

    // the weekly rule without a day mask repeats on the start's weekday
    let bare = CalendarWriter.recurrenceRule(.init(type: .weekly, frequency: 1), start: start, in: vancouver)
    #expect(bare.daysOfTheWeek?.map(\.dayOfTheWeek) == [.monday])
}

@Test func fillReplacesRulesAndAlarms() {
    var event = SyncedEvent(date: PalmDate(year: 2026, month: 10, day: 19),
                            time: .init(start: PalmTime(hour: 8, minute: 0), end: PalmTime(hour: 8, minute: 15)),
                            title: "Meds", alarm: .init(advance: 1, unit: .hours),
                            repeatRule: .init(type: .daily, frequency: 1), category: "Medicine")
    let ek = EKEvent(eventStore: store)
    CalendarWriter.fill(ek, from: event, in: vancouver)
    #expect(ek.recurrenceRules?.count == 1 && ek.alarms?.count == 1)
    event.repeatRule = nil
    event.alarm = nil
    CalendarWriter.fill(ek, from: event, in: vancouver)
    #expect(ek.recurrenceRules?.isEmpty ?? true)
    #expect(ek.alarms?.isEmpty ?? true)
}

@Test func palmRoundTripThroughTheMacModel() {
    // what the writer puts into EventKit, CalendarSource reads back as the same Palm rule
    let start = PalmDate(year: 2026, month: 10, day: 13)
    let ek = EKEvent(eventStore: store)
    var rule = CalendarEvent.Repeat(type: .weekly, frequency: 1)
    rule.weekdays = [.tuesday, .thursday]
    CalendarWriter.fill(ek, from: SyncedEvent(date: start, title: "x", repeatRule: rule, category: "c"), in: vancouver)
    let mac = CalendarSource.macRecurrence(ek.recurrenceRules ?? [])
    #expect(mac?.frequency == .weekly && mac?.daysOfTheWeek.map(\.weekday) == [3, 5])
    let back = CalendarBuilder.palmRule(mac!, startDate: start, endDate: nil, defaultWeekStart: 0)
    #expect(back?.type == .weekly && back?.weekdays == [.tuesday, .thursday])
}
