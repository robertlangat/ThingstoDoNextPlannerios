import Foundation

public enum TaskView: Hashable, Sendable {
    case inbox, today, upcoming, starred, completed
    case list(String)

    public static let builtIn: [TaskView] = [.inbox, .today, .upcoming, .starred, .completed]

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .starred: return "Starred"
        case .completed: return "Completed"
        case .list: return "List"
        }
    }
}

public enum DateFilter: String, CaseIterable, Sendable {
    case any = "Any date", today = "Today", thisWeek = "Next 7 days", overdue = "Overdue", noDate = "No date"
}

public enum StatusFilter: String, CaseIterable, Sendable { case open = "Open", completed = "Completed", all = "All" }

public struct Filters: Equatable, Sendable {
    /// nil = any list; "" = Inbox only.
    public var listId: String?
    public var priorities: Set<Int> = []
    public var date: DateFilter = .any
    public var status: StatusFilter = .open
    public init(listId: String? = nil, priorities: Set<Int> = [], date: DateFilter = .any, status: StatusFilter = .open) {
        self.listId = listId; self.priorities = priorities; self.date = date; self.status = status
    }
    public var active: Bool { listId != nil || !priorities.isEmpty || date != .any || status != .open }
}

public struct TaskSection: Identifiable, Sendable {
    public var title: String?
    public var items: [TaskOccurrence]
    public var id: String { title ?? "_" }
}

public enum TaskViews {
    static func candidates(_ data: AppData, _ today: LocalDate, _ status: StatusFilter) -> [TaskOccurrence] {
        data.tasks.flatMap { t -> [TaskOccurrence] in
            var out: [TaskOccurrence] = []
            if !t.isRecurring {
                let o = data.occurrence(t, t.dueDate)
                if status == .all || (status == .open) != o.completed { out.append(o) }
            } else {
                if status != .completed, let c = data.currentOccurrence(t, today: today) { out.append(c) }
                if status != .open {
                    out += data.completedDates(t.id).sorted(by: >).prefix(5).map { data.occurrence(t, $0) }
                }
            }
            return out
        }
    }

    static func apply(_ items: [TaskOccurrence], _ f: Filters, _ today: LocalDate) -> [TaskOccurrence] {
        items.filter { o in
            if let l = f.listId, (o.task.listId ?? "") != l { return false }
            if !f.priorities.isEmpty && !f.priorities.contains(o.task.priority) { return false }
            switch f.date {
            case .any: return true
            case .today: return o.date == today
            case .thisWeek: return o.date.map { $0 >= today && $0 <= today.plusDays(6) } ?? false
            case .overdue: return o.isOverdue(today)
            case .noDate: return o.date == nil
            }
        }
    }

    public static func build(_ view: TaskView, _ data: AppData, today: LocalDate, query: String, filters: Filters,
                             dateLabel: (LocalDate) -> String = { $0.isoString }) -> [TaskSection] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let hits = candidates(data, today, filters.status).filter { o in
                o.task.title.lowercased().contains(q) || o.task.notes.lowercased().contains(q)
                    || data.subtasks(of: o.task.id).contains { $0.title.lowercased().contains(q) }
                    || (o.list?.name.lowercased().contains(q) ?? false)
            }
            return [TaskSection(title: "Search results", items: AppData.sort(apply(hits, filters, today)))]
        }
        let anyStatus: Filters = { var f = filters; f.status = .all; return f }()
        switch view {
        case .inbox:
            return [TaskSection(title: nil, items: AppData.sort(apply(candidates(data, today, filters.status).filter { $0.task.listId == nil }, filters, today)))]
        case .list(let id):
            return [TaskSection(title: nil, items: AppData.sort(apply(candidates(data, today, filters.status).filter { $0.task.listId == id }, filters, today)))]
        case .starred:
            return [TaskSection(title: nil, items: AppData.sort(apply(candidates(data, today, filters.status).filter { $0.task.starred }, filters, today)))]
        case .today:
            let todays = data.occurrences(from: today, to: today)
            let overdue = data.occurrences(from: today.plusDays(-30), to: today.plusDays(-1)).filter { !$0.completed }
            let showDone = filters.status != .open
            var out: [TaskSection] = []
            let o = AppData.sort(apply(overdue, anyStatus, today))
            if !o.isEmpty { out.append(TaskSection(title: "Overdue", items: o)) }
            out.append(TaskSection(title: "Today", items: AppData.sort(apply(todays.filter { showDone || !$0.completed }, anyStatus, today))))
            let done = AppData.sort(apply(todays.filter(\.completed), anyStatus, today))
            if !showDone && !done.isEmpty { out.append(TaskSection(title: "Done today", items: done)) }
            return out
        case .upcoming:
            let items = apply(data.occurrences(from: today.plusDays(1), to: today.plusDays(30)), anyStatus, today)
                .filter { filters.status == .all || (filters.status == .open) != $0.completed }
            let groups = Dictionary(grouping: items) { $0.date! }
            return groups.keys.sorted().map { TaskSection(title: dateLabel($0), items: AppData.sort(groups[$0]!)) }
        case .completed:
            let oneOffs = data.tasks.filter { !$0.isRecurring && $0.completed }.map { data.occurrence($0, $0.dueDate) }
            let byId = Dictionary(data.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let recurring = data.occurrences.filter(\.completed).compactMap { o in byId[o.taskId].map { data.occurrence($0, o.date) } }
            let stamp: (TaskOccurrence) -> Int64 = { o in
                o.task.isRecurring
                    ? (data.occurrences.first { $0.taskId == o.task.id && $0.date == o.date }?.completedAt ?? 0)
                    : (o.task.completedAt ?? 0)
            }
            return [TaskSection(title: nil, items: apply(oneOffs + recurring, anyStatus, today).sorted { stamp($0) > stamp($1) })]
        }
    }

    /// Focus view: up to three open tasks for today/overdue (plus important undated), by priority.
    public static func focus(_ data: AppData, today: LocalDate) -> [TaskOccurrence] {
        let due = data.occurrences(from: today.plusDays(-30), to: today).filter { !$0.completed }
        let undated = data.tasks.filter { $0.dueDate == nil && !$0.completed && ($0.priority >= 2 || $0.starred) }.map { data.occurrence($0, nil) }
        return Array((due + undated).sorted { a, b in
            if a.task.priority != b.task.priority { return a.task.priority > b.task.priority }
            if a.task.starred != b.task.starred { return a.task.starred }
            let da = a.date?.epochDay ?? Int.max, db = b.date?.epochDay ?? Int.max
            if da != db { return da < db }
            return (a.time?.minutes ?? -1) < (b.time?.minutes ?? -1)
        }.prefix(3))
    }
}
