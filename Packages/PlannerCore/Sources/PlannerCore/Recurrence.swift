import Foundation

/// Recurrence rules. Same rules and the same string format as the Android app (see docs/RECURRENCE.md).
/// - Occurrences are dates; the time of day is applied later in the device's current zone.
/// - Monthly rules clamp to the month's last day without drifting (Jan 31 -> Feb 28 -> Mar 31).
/// - Yearly Feb 29 falls on Feb 28 in non-leap years.
/// - COUNT includes EXDATEs (RFC 5545), so deleting one occurrence never extends the series.
public enum Frequency: String, CaseIterable, Codable, Sendable { case DAILY, WEEKDAYS, WEEKLY, MONTHLY, YEARLY }

public enum RecurrenceEnd: Hashable, Sendable {
    case never
    case until(LocalDate)
    case count(Int)
}

public struct RecurrenceRule: Hashable, Sendable {
    public var frequency: Frequency
    public var interval: Int
    /// ISO weekdays (1 = Mon). Only for WEEKLY; empty = start date's weekday.
    public var byDays: Set<Int>
    public var end: RecurrenceEnd
    public var exDates: Set<LocalDate>

    public init(_ frequency: Frequency, interval: Int = 1, byDays: Set<Int> = [], end: RecurrenceEnd = .never, exDates: Set<LocalDate> = []) {
        self.frequency = frequency
        self.interval = max(1, min(999, interval))
        self.byDays = byDays
        self.end = end
        self.exDates = exDates
    }

    public func withExDate(_ d: LocalDate) -> RecurrenceRule { var r = self; r.exDates.insert(d); return r }

    func effectiveDays(_ start: LocalDate) -> [Int] { (byDays.isEmpty ? [start.weekday] : Array(byDays)).sorted() }

    private static let dayCodes = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]

    public func format() -> String {
        var parts = ["FREQ=\(frequency.rawValue)"]
        if interval != 1 { parts.append("INTERVAL=\(interval)") }
        if !byDays.isEmpty { parts.append("BYDAY=" + byDays.sorted().map { Self.dayCodes[$0 - 1] }.joined(separator: ",")) }
        switch end {
        case .never: break
        case .until(let d): parts.append("UNTIL=\(d.isoString)")
        case .count(let n): parts.append("COUNT=\(n)")
        }
        if !exDates.isEmpty { parts.append("EXDATE=" + exDates.sorted().map(\.isoString).joined(separator: ",")) }
        return parts.joined(separator: ";")
    }

    public static func parse(_ text: String?) -> RecurrenceRule? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var map: [String: String] = [:]
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            map[kv[0].uppercased()] = kv[1]
        }
        guard let f = map["FREQ"].flatMap({ Frequency(rawValue: $0.uppercased()) }) else { return nil }
        var end = RecurrenceEnd.never
        if let u = map["UNTIL"] { guard let d = LocalDate(iso: u) else { return nil }; end = .until(d) }
        else if let c = map["COUNT"] { guard let n = Int(c), n >= 1 else { return nil }; end = .count(n) }
        var days = Set<Int>()
        if let b = map["BYDAY"] {
            for code in b.split(separator: ",") {
                guard let i = dayCodes.firstIndex(of: code.uppercased()) else { return nil }
                days.insert(i + 1)
            }
        }
        var ex = Set<LocalDate>()
        if let e = map["EXDATE"] {
            for s in e.split(separator: ",") { guard let d = LocalDate(iso: String(s)) else { return nil }; ex.insert(d) }
        }
        let interval = map["INTERVAL"].flatMap { Int($0) } ?? 1
        return RecurrenceRule(f, interval: interval, byDays: days, end: end, exDates: ex)
    }

    public func describe(start: LocalDate) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let months = Calendar(identifier: .gregorian).monthSymbols
        var base: String
        switch frequency {
        case .DAILY: base = interval == 1 ? "Every day" : "Every \(interval) days"
        case .WEEKDAYS: base = "Every weekday"
        case .WEEKLY:
            base = (interval == 1 ? "Weekly" : "Every \(interval) weeks") + " on " + effectiveDays(start).map { names[$0 - 1] }.joined(separator: ", ")
        case .MONTHLY:
            base = (interval == 1 ? "Monthly" : "Every \(interval) months") + " on day \(start.day)" + (start.day > 28 ? " (or last day)" : "")
        case .YEARLY:
            base = (interval == 1 ? "Yearly" : "Every \(interval) years") + " on \(months[start.month - 1]) \(start.day)"
        }
        switch end {
        case .never: return base
        case .until(let d): return base + ", until \(d.isoString)"
        case .count(let n): return base + ", \(n) times"
        }
    }
}

public enum RecurrenceEngine {
    static let maxIterations = 50_000

    /// Candidate dates (unbounded), before start/end filtering.
    private static func candidates(_ start: LocalDate, _ rule: RecurrenceRule) -> AnySequence<LocalDate> {
        switch rule.frequency {
        case .DAILY:
            return AnySequence(sequence(first: start) { $0.plusDays(rule.interval) })
        case .WEEKDAYS:
            return AnySequence(sequence(first: start) { $0.plusDays(1) }.lazy.filter { $0.weekday <= 5 })
        case .WEEKLY:
            let days = rule.effectiveDays(start)
            let monday = start.plusDays(-(start.weekday - 1))
            return AnySequence(sequence(first: 0) { $0 + 1 }.lazy.flatMap { week -> [LocalDate] in
                let m = monday.plusDays(week * 7 * rule.interval)
                return days.map { m.plusDays($0 - 1) }
            })
        case .MONTHLY:
            return AnySequence(sequence(first: 0) { $0 + 1 }.lazy.map { start.plusMonths($0 * rule.interval, anchorDay: start.day) })
        case .YEARLY:
            return AnySequence(sequence(first: 0) { $0 + 1 }.lazy.map { start.plusMonths($0 * 12 * rule.interval, anchorDay: start.day) })
        }
    }

    /// The raw series in order (EXDATEs not removed), honouring UNTIL and COUNT. Stops at [limit].
    public static func series(_ start: LocalDate, _ rule: RecurrenceRule, through limit: LocalDate) -> [LocalDate] {
        var out: [LocalDate] = []
        var produced = 0
        var iterations = 0
        for c in candidates(start, rule) {
            iterations += 1
            if iterations > maxIterations { break }
            if c < start { continue }
            if c > limit { break }
            if case .until(let u) = rule.end, c > u { break }
            if case .count(let n) = rule.end, produced >= n { break }
            produced += 1
            out.append(c)
        }
        return out
    }

    /// First [n] raw occurrences (for tests and "next" lookups).
    public static func first(_ n: Int, _ start: LocalDate, _ rule: RecurrenceRule) -> [LocalDate] {
        var out: [LocalDate] = []
        var produced = 0
        var iterations = 0
        for c in candidates(start, rule) {
            iterations += 1
            if iterations > maxIterations || out.count >= n { break }
            if c < start { continue }
            if case .until(let u) = rule.end, c > u { break }
            if case .count(let k) = rule.end, produced >= k { break }
            produced += 1
            out.append(c)
        }
        return out
    }

    public static func occurrences(_ start: LocalDate, _ rule: RecurrenceRule, from: LocalDate, to: LocalDate) -> [LocalDate] {
        guard to >= from else { return [] }
        return series(start, rule, through: to).filter { $0 >= from && !rule.exDates.contains($0) }
    }

    public static func isOccurrence(_ start: LocalDate, _ rule: RecurrenceRule, _ date: LocalDate) -> Bool {
        !rule.exDates.contains(date) && series(start, rule, through: date).last == date
    }

    public static func next(onOrAfter from: LocalDate, _ start: LocalDate, _ rule: RecurrenceRule, horizonDays: Int = 3660) -> LocalDate? {
        series(start, rule, through: from.plusDays(horizonDays)).first { $0 >= from && !rule.exDates.contains($0) }
    }

    /// Split for "this and future occurrences". Returns (old rule or nil if [at] is the first occurrence, new rule).
    public static func split(_ start: LocalDate, _ rule: RecurrenceRule, at: LocalDate) -> (RecurrenceRule?, RecurrenceRule) {
        let before = series(start, rule, through: at.plusDays(-1))
        var newRule = rule
        newRule.exDates = rule.exDates.filter { $0 >= at }
        if case .count(let n) = rule.end { newRule.end = .count(max(1, n - before.count)) }
        if before.isEmpty { return (nil, newRule) }
        var old = rule
        old.exDates = rule.exDates.filter { $0 < at }
        if case .count = rule.end { old.end = .count(before.count) } else { old.end = .until(at.plusDays(-1)) }
        return (old, newRule)
    }
}
