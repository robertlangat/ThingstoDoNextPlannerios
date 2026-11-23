import Foundation

public struct Ratio: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public init(_ done: Int, _ total: Int) { self.done = done; self.total = total }
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    static func + (a: Ratio, b: Ratio) -> Ratio { Ratio(a.done + b.done, a.total + b.total) }
}

public struct ProgressStats: Equatable, Sendable {
    public var today: Ratio
    public var thisWeek: Ratio
    public var overdue: Int
    /// Key "" = Inbox.
    public var byList: [String: Ratio]
}

/// Recurring tasks count each occurrence separately.
public enum ProgressCalculator {
    public static func compute(_ data: AppData, today: LocalDate) -> ProgressStats {
        let weekStart = today.plusDays(-(today.weekday - 1))
        let weekEnd = weekStart.plusDays(6)
        var todayR = Ratio(0, 0), weekR = Ratio(0, 0), overdue = 0
        var byList: [String: Ratio] = [:]
        for t in data.tasks {
            let key = t.listId ?? ""
            if let rule = t.rule, let start = t.dueDate {
                let done = data.completedDates(t.id)
                let week = RecurrenceEngine.occurrences(start, rule, from: weekStart, to: weekEnd)
                let w = Ratio(week.filter { done.contains($0) }.count, week.count)
                weekR = weekR + w
                byList[key] = (byList[key] ?? Ratio(0, 0)) + w
                if !RecurrenceEngine.occurrences(start, rule, from: today, to: today).isEmpty {
                    todayR = todayR + Ratio(done.contains(today) ? 1 : 0, 1)
                }
                overdue += RecurrenceEngine.occurrences(start, rule, from: today.plusDays(-30), to: today.plusDays(-1))
                    .filter { !done.contains($0) }.count
            } else {
                let d = t.completed ? 1 : 0
                byList[key] = (byList[key] ?? Ratio(0, 0)) + Ratio(d, 1)
                if t.dueDate == today { todayR = todayR + Ratio(d, 1) }
                if let due = t.dueDate, due >= weekStart, due <= weekEnd { weekR = weekR + Ratio(d, 1) }
                if let due = t.dueDate, due < today, !t.completed { overdue += 1 }
            }
        }
        return ProgressStats(today: todayR, thisWeek: weekR, overdue: overdue, byList: byList)
    }
}

/// Phone -> watch payload (WatchConnectivity application context).
public struct WatchTask: Codable, Hashable, Identifiable, Sendable {
    public var taskId: String
    public var date: String?
    public var title: String
    public var time: String?
    public var done: Bool
    public var priority: Int
    public var overdue: Bool
    public var id: String { "\(taskId)@\(date ?? "none")" }
    public init(taskId: String, date: String?, title: String, time: String?, done: Bool, priority: Int, overdue: Bool) {
        self.taskId = taskId; self.date = date; self.title = title; self.time = time
        self.done = done; self.priority = priority; self.overdue = overdue
    }
}

public struct WatchPayload: Codable, Hashable, Sendable {
    public var updatedAt: Date
    public var today: [WatchTask]
    public var upcoming: [WatchTask]
    public init(updatedAt: Date, today: [WatchTask], upcoming: [WatchTask]) {
        self.updatedAt = updatedAt; self.today = today; self.upcoming = upcoming
    }
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ d: Data) -> WatchPayload? { try? JSONDecoder().decode(WatchPayload.self, from: d) }
}
