import Foundation

/// A calendar date as the Palm packs it into 16 bits:
/// `(year - 1904) << 9 | month << 5 | day`, month 1-12, day 1-31.
/// 0xFFFF means "no date" and is represented by nil where it can occur.
public struct PalmDate: Equatable, Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public static let none: UInt16 = 0xFFFF

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(packed: UInt16) {
        year = 1904 + Int(packed >> 9)
        month = Int((packed >> 5) & 0x0F)
        day = Int(packed & 0x1F)
    }

    public var packed: UInt16 {
        UInt16(clamping: (year - 1904) << 9 | month << 5 | day)
    }

    public static func < (a: PalmDate, b: PalmDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day)
    }
}

/// A time of day, minute resolution, as the Palm stores it: hour, minute.
public struct PalmTime: Equatable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public static func < (a: PalmTime, b: PalmTime) -> Bool {
        (a.hour, a.minute) < (b.hour, b.minute)
    }
}
