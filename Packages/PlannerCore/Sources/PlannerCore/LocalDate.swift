import Foundation

/// A calendar date with no time zone (like java.time.LocalDate). Stored as days since 1970-01-01,
/// which is also how the Android app stores dates, so sync files are interchangeable.
public struct LocalDate: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    public let epochDay: Int

    public init(epochDay: Int) { self.epochDay = epochDay }

    public init(_ year: Int, _ month: Int, _ day: Int) {
        epochDay = LocalDate.daysFromCivil(year, month, day)
    }

    /// Parses "yyyy-MM-dd".
    public init?(iso: String) {
        let parts = iso.split(separator: "-").map { Int($0) }
        guard parts.count == 3, let y = parts[0], let m = parts[1], let d = parts[2],
              (1...12).contains(m), d >= 1, d <= LocalDate.lengthOfMonth(y, m) else { return nil }
        self.init(y, m, d)
    }

    public var components: (year: Int, month: Int, day: Int) { LocalDate.civilFromDays(epochDay) }
    public var year: Int { components.year }
    public var month: Int { components.month }
    public var day: Int { components.day }

    /// ISO weekday: 1 = Monday ... 7 = Sunday.
    public var weekday: Int { ((epochDay % 7 + 7 + 3) % 7) + 1 }

    public func plusDays(_ n: Int) -> LocalDate { LocalDate(epochDay: epochDay + n) }

    public func plusMonths(_ n: Int, anchorDay: Int? = nil) -> LocalDate {
        let c = components
        let total = c.year * 12 + (c.month - 1) + n
        let y = Int((Double(total) / 12).rounded(.down))
        let m = total - y * 12 + 1
        let d = min(anchorDay ?? c.day, LocalDate.lengthOfMonth(y, m))
        return LocalDate(y, m, d)
    }

    public var isoString: String {
        let c = components
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    public var description: String { isoString }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { a.epochDay < b.epochDay }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

    public static func lengthOfMonth(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return isLeap(y) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Today in the given time zone.
    public static func today(in tz: TimeZone = .current, now: Date = Date()) -> LocalDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return LocalDate(c.year!, c.month!, c.day!)
    }

    // Howard Hinnant's civil-date algorithms (proleptic Gregorian).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    // Codable as "yyyy-MM-dd".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let d = LocalDate(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(isoString)
    }
}

/// Minutes after midnight (wall clock).
public struct LocalTime: Hashable, Comparable, Codable, Sendable {
    public let minutes: Int
    public init(minutes: Int) { self.minutes = max(0, min(24 * 60 - 1, minutes)) }
    public init(_ hour: Int, _ minute: Int) { self.init(minutes: hour * 60 + minute) }
    public var hour: Int { minutes / 60 }
    public var minute: Int { minutes % 60 }
    public static func < (a: LocalTime, b: LocalTime) -> Bool { a.minutes < b.minutes }
    public var hhmm: String { String(format: "%02d:%02d", hour, minute) }
}

/// A wall-clock date and time with no zone, used by the planner.
public struct LocalDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// Minutes since 1970-01-01T00:00 (wall clock).
    public let totalMinutes: Int
    public init(totalMinutes: Int) { self.totalMinutes = totalMinutes }
    public init(_ date: LocalDate, _ time: LocalTime) { totalMinutes = date.epochDay * 1440 + time.minutes }
    public var date: LocalDate { LocalDate(epochDay: Int((Double(totalMinutes) / 1440).rounded(.down))) }
    public var time: LocalTime { LocalTime(minutes: totalMinutes - date.epochDay * 1440) }
    public func plusMinutes(_ m: Int) -> LocalDateTime { LocalDateTime(totalMinutes: totalMinutes + m) }
    public static func < (a: LocalDateTime, b: LocalDateTime) -> Bool { a.totalMinutes < b.totalMinutes }
    /// "yyyy-MM-ddTHH:mm"
    public var description: String { "\(date.isoString)T\(time.hhmm)" }

    public init?(iso: String) {
        let s = iso.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: "T")
        guard parts.count == 2, let d = LocalDate(iso: String(parts[0])) else { return nil }
        let t = parts[1].split(separator: ":").prefix(2).map { Int($0) }
        guard t.count == 2, let h = t[0], let m = t[1], (0...23).contains(h), (0...59).contains(m) else { return nil }
        self.init(d, LocalTime(h, m))
    }
}
