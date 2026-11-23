import Foundation

/// Fields every synced row carries (see docs/SYNC.md).
public protocol Versioned {
    var id: String { get }
    var version: Int64 { get set }
    var deviceId: String { get set }
    var deleted: Bool { get set }
    var seenDeleteVersion: Int64 { get set }
}

public struct TaskList: Codable, Hashable, Identifiable, Versioned, Sendable {
    public var id: String
    public var name: String
    /// ARGB, same as Android.
    public var color: Int?
    public var icon: String?
    public var sortOrder: Int
    public var version: Int64
    public var deviceId: String
    public var deleted = false
    public var seenDeleteVersion: Int64 = 0

    public init(id: String, name: String, color: Int?, icon: String?, sortOrder: Int, version: Int64, deviceId: String) {
        self.id = id; self.name = name; self.color = color; self.icon = icon; self.sortOrder = sortOrder
        self.version = version; self.deviceId = deviceId
    }
}

public struct TaskItem: Codable, Hashable, Identifiable, Versioned, Sendable {
    public var id: String
    public var listId: String?
    public var title: String
    public var notes: String = ""
    /// 0 none, 1 low, 2 medium, 3 high.
    public var priority: Int = 0
    public var starred = false
    public var dueDate: LocalDate?
    /// nil with a date = all-day.
    public var dueTime: LocalTime?
    public var rrule: String?
    public var completed = false
    public var completedAt: Int64?
    public var reminderOffsets: [Int] = []
    public var estimatedMinutes: Int?
    public var seriesParentId: String?
    public var createdAt: Int64
    public var sortOrder: Int64
    public var version: Int64
    public var deviceId: String
    public var deleted = false
    public var seenDeleteVersion: Int64 = 0

    public init(id: String, listId: String?, title: String, createdAt: Int64, version: Int64, deviceId: String) {
        self.id = id; self.listId = listId; self.title = title; self.createdAt = createdAt
        self.sortOrder = createdAt; self.version = version; self.deviceId = deviceId
    }

    public var rule: RecurrenceRule? { RecurrenceRule.parse(rrule) }
    public var isRecurring: Bool { rrule != nil }
}

public struct Subtask: Codable, Hashable, Identifiable, Versioned, Sendable {
    public var id: String
    public var taskId: String
    public var title: String
    public var done = false
    public var sortOrder = 0
    public var version: Int64
    public var deviceId: String
    public var deleted = false
    public var seenDeleteVersion: Int64 = 0

    public init(id: String, taskId: String, title: String, done: Bool, sortOrder: Int, version: Int64, deviceId: String) {
        self.id = id; self.taskId = taskId; self.title = title; self.done = done; self.sortOrder = sortOrder
        self.version = version; self.deviceId = deviceId
    }
}

/// Completion of one occurrence of a recurring task. id = "taskId@yyyy-mm-dd".
public struct Occurrence: Codable, Hashable, Identifiable, Versioned, Sendable {
    public var id: String
    public var taskId: String
    public var date: LocalDate
    public var completed: Bool
    public var completedAt: Int64?
    public var version: Int64
    public var deviceId: String
    public var deleted = false
    public var seenDeleteVersion: Int64 = 0

    public init(taskId: String, date: LocalDate, completed: Bool, completedAt: Int64?, version: Int64, deviceId: String) {
        self.id = Occurrence.idFor(taskId, date); self.taskId = taskId; self.date = date; self.completed = completed
        self.completedAt = completedAt; self.version = version; self.deviceId = deviceId
    }

    public static func idFor(_ taskId: String, _ date: LocalDate) -> String { "\(taskId)@\(date.isoString)" }
}

/// All rows, tombstones included. Persisted as one JSON file and shared with the widget.
public struct Database: Codable, Sendable {
    public var lists: [TaskList] = []
    public var tasks: [TaskItem] = []
    public var subtasks: [Subtask] = []
    public var occurrences: [Occurrence] = []
    public init() {}
}

// MARK: - Sync mapping (field names identical to the Android app's SyncMapping)

public enum SyncMapping {
    public static let list = "list", task = "task", subtask = "subtask", occurrence = "occurrence"

    public static func records(_ db: Database) -> [SyncRecord] {
        var out: [SyncRecord] = []
        for l in db.lists {
            out.append(SyncRecord(type: list, id: l.id, version: l.version, deviceId: l.deviceId, deleted: l.deleted, data: [
                "name": .string(l.name), "color": .from(l.color), "icon": .from(l.icon), "sortOrder": .int(l.sortOrder),
            ], seenDeleteVersion: l.seenDeleteVersion))
        }
        for t in db.tasks {
            out.append(SyncRecord(type: task, id: t.id, version: t.version, deviceId: t.deviceId, deleted: t.deleted, data: [
                "listId": .from(t.listId), "title": .string(t.title), "notes": .string(t.notes), "priority": .int(t.priority),
                "starred": .bool(t.starred), "dueDate": .from(t.dueDate?.epochDay), "dueTimeMinutes": .from(t.dueTime?.minutes),
                "rrule": .from(t.rrule), "completed": .bool(t.completed), "completedAt": .from(t.completedAt.map { Int($0) }),
                "reminderOffsets": .string(t.reminderOffsets.map(String.init).joined(separator: ",")),
                "estimatedMinutes": .from(t.estimatedMinutes), "seriesParentId": .from(t.seriesParentId),
                "createdAt": .int(Int(t.createdAt)), "sortOrder": .int(Int(t.sortOrder)),
            ], seenDeleteVersion: t.seenDeleteVersion))
        }
        for s in db.subtasks {
            out.append(SyncRecord(type: subtask, id: s.id, version: s.version, deviceId: s.deviceId, deleted: s.deleted, data: [
                "taskId": .string(s.taskId), "title": .string(s.title), "done": .bool(s.done), "sortOrder": .int(s.sortOrder),
            ], seenDeleteVersion: s.seenDeleteVersion))
        }
        for o in db.occurrences {
            out.append(SyncRecord(type: occurrence, id: o.id, version: o.version, deviceId: o.deviceId, deleted: o.deleted, data: [
                "taskId": .string(o.taskId), "date": .int(o.date.epochDay), "completed": .bool(o.completed),
                "completedAt": .from(o.completedAt.map { Int($0) }),
            ], seenDeleteVersion: o.seenDeleteVersion))
        }
        return out
    }

    /// Applies merged records (and purges) to a database copy.
    public static func apply(_ records: [SyncRecord], purge: Set<String>, to db: inout Database) {
        func upsert<T: Identifiable>(_ arr: inout [T], _ v: T) where T.ID == String {
            if let i = arr.firstIndex(where: { $0.id == v.id }) { arr[i] = v } else { arr.append(v) }
        }
        for r in records {
            let d = r.data
            switch r.type {
            case list:
                guard let name = d["name"]?.string else { continue }
                var l = TaskList(id: r.id, name: name, color: d["color"]?.int, icon: d["icon"]?.string,
                                 sortOrder: d["sortOrder"]?.int ?? 0, version: r.version, deviceId: r.deviceId)
                l.deleted = r.deleted; l.seenDeleteVersion = r.seenDeleteVersion
                upsert(&db.lists, l)
            case task:
                guard let title = d["title"]?.string else { continue }
                var t = TaskItem(id: r.id, listId: d["listId"]?.string, title: title,
                                 createdAt: Int64(d["createdAt"]?.int ?? 0), version: r.version, deviceId: r.deviceId)
                t.notes = d["notes"]?.string ?? ""
                t.priority = d["priority"]?.int ?? 0
                t.starred = d["starred"]?.bool ?? false
                t.dueDate = d["dueDate"]?.int.map(LocalDate.init(epochDay:))
                t.dueTime = d["dueTimeMinutes"]?.int.map(LocalTime.init(minutes:))
                t.rrule = d["rrule"]?.string
                t.completed = d["completed"]?.bool ?? false
                t.completedAt = d["completedAt"]?.int.map(Int64.init)
                t.reminderOffsets = (d["reminderOffsets"]?.string ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                t.estimatedMinutes = d["estimatedMinutes"]?.int
                t.seriesParentId = d["seriesParentId"]?.string
                t.sortOrder = Int64(d["sortOrder"]?.int ?? 0)
                t.deleted = r.deleted; t.seenDeleteVersion = r.seenDeleteVersion
                upsert(&db.tasks, t)
            case subtask:
                guard let taskId = d["taskId"]?.string else { continue }
                var s = Subtask(id: r.id, taskId: taskId, title: d["title"]?.string ?? "", done: d["done"]?.bool ?? false,
                                sortOrder: d["sortOrder"]?.int ?? 0, version: r.version, deviceId: r.deviceId)
                s.deleted = r.deleted; s.seenDeleteVersion = r.seenDeleteVersion
                upsert(&db.subtasks, s)
            case occurrence:
                guard let taskId = d["taskId"]?.string, let day = d["date"]?.int else { continue }
                var o = Occurrence(taskId: taskId, date: LocalDate(epochDay: day), completed: d["completed"]?.bool ?? false,
                                   completedAt: d["completedAt"]?.int.map(Int64.init), version: r.version, deviceId: r.deviceId)
                o.id = r.id
                o.deleted = r.deleted; o.seenDeleteVersion = r.seenDeleteVersion
                upsert(&db.occurrences, o)
            default: continue
            }
        }
        if !purge.isEmpty {
            db.lists.removeAll { purge.contains("\(list):\($0.id)") }
            db.tasks.removeAll { purge.contains("\(task):\($0.id)") }
            db.subtasks.removeAll { purge.contains("\(subtask):\($0.id)") }
            db.occurrences.removeAll { purge.contains("\(occurrence):\($0.id)") }
        }
    }
}

// MARK: - View helpers

public struct TaskOccurrence: Hashable, Identifiable, Sendable {
    public var task: TaskItem
    public var date: LocalDate?
    public var completed: Bool
    public var list: TaskList?
    public var subtasksDone: Int
    public var subtasksTotal: Int
    public var id: String { "\(task.id)@\(date?.isoString ?? "none")" }
    public var time: LocalTime? { task.dueTime }
    public func isOverdue(_ today: LocalDate) -> Bool { !completed && (date.map { $0 < today } ?? false) }
}

/// Live (non-deleted) data with query helpers, used by the app, the widget and progress stats.
public struct AppData: Sendable {
    public let tasks: [TaskItem]
    public let lists: [TaskList]
    public let subtasks: [Subtask]
    public let occurrences: [Occurrence]
    public let listsById: [String: TaskList]
    let subtasksByTask: [String: [Subtask]]
    let completedByTask: [String: Set<LocalDate>]

    public init(_ db: Database) {
        tasks = db.tasks.filter { !$0.deleted }
        lists = db.lists.filter { !$0.deleted }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
        subtasks = db.subtasks.filter { !$0.deleted }.sorted { $0.sortOrder < $1.sortOrder }
        occurrences = db.occurrences.filter { !$0.deleted }
        listsById = Dictionary(lists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        subtasksByTask = Dictionary(grouping: subtasks, by: \.taskId)
        completedByTask = Dictionary(grouping: occurrences.filter(\.completed), by: \.taskId).mapValues { Set($0.map(\.date)) }
    }

    public func subtasks(of id: String) -> [Subtask] { subtasksByTask[id] ?? [] }
    public func completedDates(_ id: String) -> Set<LocalDate> { completedByTask[id] ?? [] }

    public func occurrence(_ t: TaskItem, _ date: LocalDate?) -> TaskOccurrence {
        let subs = subtasks(of: t.id)
        let done = (t.isRecurring && date != nil) ? completedDates(t.id).contains(date!) : t.completed
        return TaskOccurrence(task: t, date: date, completed: done, list: t.listId.flatMap { listsById[$0] },
                              subtasksDone: subs.filter(\.done).count, subtasksTotal: subs.count)
    }

    public func occurrences(from: LocalDate, to: LocalDate) -> [TaskOccurrence] {
        tasks.flatMap { t -> [TaskOccurrence] in
            guard let start = t.dueDate else { return [] }
            guard let rule = t.rule else { return (start >= from && start <= to) ? [occurrence(t, start)] : [] }
            return RecurrenceEngine.occurrences(start, rule, from: from, to: to).map { occurrence(t, $0) }
        }
    }

    /// Earliest open occurrence in the last week, otherwise the next upcoming one.
    public func currentOccurrence(_ t: TaskItem, today: LocalDate) -> TaskOccurrence? {
        guard let start = t.dueDate else { return occurrence(t, nil) }
        guard let rule = t.rule else { return occurrence(t, start) }
        let done = completedDates(t.id)
        if let open = RecurrenceEngine.occurrences(start, rule, from: today.plusDays(-7), to: today).first(where: { !done.contains($0) }) {
            return occurrence(t, open)
        }
        let next = RecurrenceEngine.series(start, rule, through: today.plusDays(3660))
            .first { $0 > today && !rule.exDates.contains($0) && !done.contains($0) }
        return next.map { occurrence(t, $0) }
    }

    public static func sort(_ items: [TaskOccurrence]) -> [TaskOccurrence] {
        items.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            let da = a.date?.epochDay ?? Int.max, db = b.date?.epochDay ?? Int.max
            if da != db { return da < db }
            let ta = a.time?.minutes ?? -1, tb = b.time?.minutes ?? -1
            if ta != tb { return ta < tb }
            if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
            return a.task.createdAt < b.task.createdAt
        }
    }
}
