import Foundation

public struct ReminderTask: Sendable {
    public var taskId: String
    public var title: String
    public var startDate: LocalDate?
    /// nil = all-day (the all-day reminder time is used).
    public var time: LocalTime?
    public var rule: RecurrenceRule?
    /// Minutes before; 0 = at the time.
    public var offsets: [Int]
    public var completedDates: Set<LocalDate>
    public var deleted: Bool

    public init(taskId: String, title: String, startDate: LocalDate?, time: LocalTime?, rule: RecurrenceRule?,
                offsets: [Int], completedDates: Set<LocalDate>, deleted: Bool = false) {
        self.taskId = taskId; self.title = title; self.startDate = startDate; self.time = time
        self.rule = rule; self.offsets = offsets; self.completedDates = completedDates; self.deleted = deleted
    }
}

public struct Snooze: Sendable {
    public var taskId: String
    public var date: LocalDate
    public var until: Date
    public init(taskId: String, date: LocalDate, until: Date) { self.taskId = taskId; self.date = date; self.until = until }
}

public struct DesiredAlarm: Hashable, Sendable {
    public var key: String
    public var taskId: String
    public var title: String
    public var occurrenceDate: LocalDate
    public var fireAt: Date
    public var isSnooze: Bool
}

/// Computes exactly which notifications should be pending. Keys are deterministic
/// (`taskId@date#offset`), and the notification request identifier is the key, so re-adding
/// replaces instead of duplicating. iOS allows 64 pending local notifications, so the planner
/// keeps the soonest [maxAlarms].
public enum ReminderPlanner {
    public static func alarmKey(_ taskId: String, _ date: LocalDate, _ offset: Int) -> String { "\(taskId)@\(date.isoString)#\(offset)" }
    public static func snoozeKey(_ taskId: String, _ date: LocalDate) -> String { "\(taskId)@\(date.isoString)#snooze" }

    /// Wall-clock occurrence -> instant in [tz].
    /// DST gap: shifts forward by the gap (01:30 on spring-forward -> 02:30). Overlap: earlier instant.
    public static func fireDate(_ date: LocalDate, _ time: LocalTime?, offsetMinutes: Int, tz: TimeZone, allDayTime: LocalTime) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let t = time ?? allDayTime
        let midnightComps = DateComponents(year: date.year, month: date.month, day: date.day, hour: 0, minute: 0)
        let dayStart = cal.date(from: midnightComps) ?? Date(timeIntervalSince1970: TimeInterval(date.epochDay * 86400))
        let match = DateComponents(hour: t.hour, minute: t.minute, second: 0)
        let wall = cal.nextDate(after: dayStart.addingTimeInterval(-1), matching: match,
                                matchingPolicy: .nextTimePreservingSmallerComponents,
                                repeatedTimePolicy: .first, direction: .forward)
            ?? dayStart.addingTimeInterval(TimeInterval(t.minutes * 60))
        return wall.addingTimeInterval(TimeInterval(-offsetMinutes * 60))
    }

    public static func desired(
        tasks: [ReminderTask], snoozes: [Snooze], now: Date, tz: TimeZone, allDayTime: LocalTime,
        deliveredKeys: Set<String> = [], horizonDays: Int = 35, missedGrace: TimeInterval = 15 * 60, maxAlarms: Int = 60
    ) -> [DesiredAlarm] {
        let today = LocalDate.today(in: tz, now: now)
        let from = today.plusDays(-1)
        let to = today.plusDays(horizonDays)
        let horizonEnd = fireDate(to.plusDays(1), LocalTime(0, 0), offsetMinutes: 0, tz: tz, allDayTime: allDayTime)
        var out: [DesiredAlarm] = []
        for t in tasks where !t.deleted && !t.offsets.isEmpty {
            guard let start = t.startDate else { continue }
            let extra = (t.offsets.max() ?? 0) / 1440 + 1
            let dates = t.rule.map { RecurrenceEngine.occurrences(start, $0, from: from, to: to.plusDays(extra)) } ?? [start]
            for d in dates where !t.completedDates.contains(d) {
                for off in Array(Set(t.offsets)).sorted() {
                    let fire = fireDate(d, t.time, offsetMinutes: off, tz: tz, allDayTime: allDayTime)
                    let key = alarmKey(t.taskId, d, off)
                    let future = fire > now
                    let missed = !future && fire > now.addingTimeInterval(-missedGrace) && !deliveredKeys.contains(key)
                    guard future || missed, fire <= horizonEnd else { continue }
                    out.append(DesiredAlarm(key: key, taskId: t.taskId, title: t.title, occurrenceDate: d,
                                            fireAt: future ? fire : now.addingTimeInterval(5), isSnooze: false))
                }
            }
        }
        let live = Dictionary(tasks.filter { !$0.deleted }.map { ($0.taskId, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        for s in snoozes {
            guard let t = live[s.taskId], !t.completedDates.contains(s.date) else { continue }
            let key = snoozeKey(s.taskId, s.date)
            if seen.contains(key) { continue }
            seen.insert(key)
            if s.until <= now && deliveredKeys.contains(key) { continue }
            out.append(DesiredAlarm(key: key, taskId: s.taskId, title: t.title, occurrenceDate: s.date,
                                    fireAt: max(s.until, now.addingTimeInterval(5)), isSnooze: true))
        }
        return Array(out.sorted { $0.fireAt < $1.fireAt }.prefix(maxAlarms))
    }

    /// [existing] = key -> scheduled fire date.
    public static func diff(_ desired: [DesiredAlarm], existing: [String: Date]) -> (schedule: [DesiredAlarm], cancel: Set<String>) {
        let keys = Set(desired.map(\.key))
        let cancel = Set(existing.keys.filter { !keys.contains($0) })
        let schedule = desired.filter { d in
            guard let e = existing[d.key] else { return true }
            return abs(e.timeIntervalSince(d.fireAt)) > 0.5
        }
        return (schedule, cancel)
    }
}
