import Foundation

public enum PlanPriority: Int, CaseIterable, Sendable { case none = 0, low, medium, high }

public enum PlanSource: String, Sendable {
    case offline = "Offline planner"
    case ai = "AI service"
}

public struct PlannerTask: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var durationMinutes: Int
    public var priority: PlanPriority
    public var deadline: LocalDateTime?
    public var subtasks: [String]
    public var notes: String?

    public init(id: String, title: String, durationMinutes: Int = 30, priority: PlanPriority = .none,
                deadline: LocalDateTime? = nil, subtasks: [String] = [], notes: String? = nil) {
        self.id = id; self.title = title; self.durationMinutes = durationMinutes; self.priority = priority
        self.deadline = deadline; self.subtasks = subtasks; self.notes = notes
    }
}

public struct TimeWindow: Hashable, Sendable {
    public var start: LocalDateTime
    public var end: LocalDateTime
    public init(_ start: LocalDateTime, _ end: LocalDateTime) { self.start = start; self.end = max(start, end) }
    public var minutes: Int { end.totalMinutes - start.totalMinutes }
    public func overlaps(_ o: TimeWindow) -> Bool { start < o.end && o.start < end }

    /// A window on [date]; an end at or before the start means "past midnight".
    public static func on(_ date: LocalDate, from: LocalTime, to: LocalTime) -> TimeWindow {
        TimeWindow(LocalDateTime(date, from), to <= from ? LocalDateTime(date.plusDays(1), to) : LocalDateTime(date, to))
    }
}

public struct BusyBlock: Hashable, Sendable {
    public var title: String
    public var window: TimeWindow
    public init(title: String, window: TimeWindow) { self.title = title; self.window = window }
}

public enum DraftFlag: String, CaseIterable, Sendable {
    case overlapsExisting, overlapsDraft, afterDeadline, outsideAvailability, unscheduled

    public var text: String {
        switch self {
        case .overlapsExisting: return "Overlaps a scheduled task"
        case .overlapsDraft: return "Overlaps another suggestion"
        case .afterDeadline: return "After its deadline"
        case .outsideAvailability: return "Outside your available time"
        case .unscheduled: return "Didn't fit - no time slot"
        }
    }
}

public struct DraftItem: Hashable, Sendable, Identifiable {
    public var id: String { task.id }
    public var task: PlannerTask
    public var slot: TimeWindow?
    public var flags: Set<DraftFlag>
    public var conflictsWith: [String]
    public var accepted: Bool

    public init(task: PlannerTask, slot: TimeWindow?, flags: Set<DraftFlag> = [], conflictsWith: [String] = [], accepted: Bool = true) {
        self.task = task; self.slot = slot; self.flags = flags; self.conflictsWith = conflictsWith; self.accepted = accepted
    }
}

public struct PlanDraft: Sendable {
    public var source: PlanSource
    public var items: [DraftItem]
    public var summary: String
    public var warnings: [String]
    public var modelName: String?
}

public struct PlanRequest: Sendable {
    public var tasks: [PlannerTask]
    public var availability: [TimeWindow]
    public var busy: [BusyBlock]
    public var bufferMinutes: Int
    public init(tasks: [PlannerTask], availability: [TimeWindow], busy: [BusyBlock], bufferMinutes: Int = 5) {
        self.tasks = tasks; self.availability = availability; self.busy = busy; self.bufferMinutes = bufferMinutes
    }
}

/// Deterministic offline scheduler: earliest deadline, then priority, then shortest; each task goes
/// into the earliest free gap inside availability that avoids existing tasks.
public enum OfflinePlanner {
    public static func plan(_ req: PlanRequest) -> PlanDraft {
        let farFuture = LocalDateTime(totalMinutes: Int.max / 2)
        let ordered = req.tasks.sorted { a, b in
            let da = a.deadline ?? farFuture, db = b.deadline ?? farFuture
            if da != db { return da < db }
            if a.priority != b.priority { return a.priority.rawValue > b.priority.rawValue }
            return a.durationMinutes < b.durationMinutes
        }
        var occupied = req.busy.map(\.window)
        let windows = req.availability.sorted { $0.start < $1.start }
        var items: [DraftItem] = []
        for t in ordered {
            let need = max(5, t.durationMinutes)
            guard let slot = findSlot(windows, occupied, need, req.bufferMinutes) else {
                items.append(DraftItem(task: t, slot: nil, flags: [.unscheduled])); continue
            }
            occupied.append(TimeWindow(slot.start, slot.end.plusMinutes(req.bufferMinutes)))
            var flags = Set<DraftFlag>()
            if let d = t.deadline, slot.end > d { flags.insert(.afterDeadline) }
            items.append(DraftItem(task: t, slot: slot, flags: flags))
        }
        let scheduled = items.filter { $0.slot != nil }
        let unscheduled = items.count - scheduled.count
        var warnings: [String] = []
        if req.availability.isEmpty { warnings.append("No available time was given, so nothing could be scheduled.") }
        if unscheduled > 0 { warnings.append("\(unscheduled) task(s) didn't fit in your available time.") }
        if items.contains(where: { $0.flags.contains(.afterDeadline) }) { warnings.append("Some tasks are scheduled after their deadline.") }
        let minutes = scheduled.reduce(0) { $0 + $1.task.durationMinutes }
        let summary = "Scheduled \(scheduled.count) of \(items.count) tasks (\(minutes) min)" + (unscheduled > 0 ? "; \(unscheduled) left unscheduled." : ".")
        return PlanDraft(source: .offline, items: sortForDisplay(items), summary: summary, warnings: warnings, modelName: nil)
    }

    static func findSlot(_ windows: [TimeWindow], _ occupied: [TimeWindow], _ minutes: Int, _ buffer: Int) -> TimeWindow? {
        for w in windows {
            var cursor = w.start
            let blockers = occupied.filter { $0.overlaps(w) }.sorted { $0.start < $1.start } + [TimeWindow(w.end, w.end)]
            for b in blockers {
                let gapEnd = min(b.start, w.end)
                if gapEnd.totalMinutes - cursor.totalMinutes >= minutes { return TimeWindow(cursor, cursor.plusMinutes(minutes)) }
                if b.end > cursor { cursor = max(cursor, b.end.plusMinutes(b.start == b.end ? 0 : buffer)) }
                if cursor >= w.end { break }
            }
        }
        return nil
    }

    public static func sortForDisplay(_ items: [DraftItem]) -> [DraftItem] {
        items.enumerated().sorted { x, y in
            let a = x.element, b = y.element
            switch (a.slot, b.slot) {
            case (nil, nil): return x.offset < y.offset
            case (nil, _): return false
            case (_, nil): return true
            case let (sa?, sb?): return sa.start == sb.start ? x.offset < y.offset : sa.start < sb.start
            }
        }.map(\.element)
    }

    /// Re-flags overlaps after edits (or AI output).
    public static func recheck(_ items: [DraftItem], busy: [BusyBlock], availability: [TimeWindow]) -> [DraftItem] {
        items.enumerated().map { idx, item in
            var it = item
            guard let slot = item.slot else { it.flags = [.unscheduled]; it.conflictsWith = []; return it }
            var flags = Set<DraftFlag>()
            var conflicts: [String] = []
            for b in busy where b.window.overlaps(slot) { flags.insert(.overlapsExisting); conflicts.append(b.title) }
            for (j, o) in items.enumerated() where j != idx && o.accepted && (o.slot?.overlaps(slot) ?? false) {
                flags.insert(.overlapsDraft); conflicts.append(o.task.title)
            }
            if !availability.isEmpty && !availability.contains(where: { slot.start >= $0.start && slot.end <= $0.end }) {
                flags.insert(.outsideAvailability)
            }
            if let d = item.task.deadline, slot.end > d { flags.insert(.afterDeadline) }
            it.flags = flags
            var seen = Set<String>()
            it.conflictsWith = conflicts.filter { seen.insert($0).inserted }
            return it
        }
    }
}

/// Validates the AI backend's structured response (same contract as the Android app).
public enum AIPlanValidator {
    public struct InvalidResponse: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func validate(_ raw: Data, planDate: LocalDate, busy: [BusyBlock], availability: [TimeWindow]) throws -> PlanDraft {
        guard let root = (try? JSONValue.parse(raw))?.object else {
            throw InvalidResponse(message: "The AI service returned something that isn't valid JSON.")
        }
        guard let rawTasks = root["tasks"]?.array else { throw InvalidResponse(message: "The AI response had no task list.") }
        var warnings: [String] = []
        if rawTasks.count > 30 { warnings.append("Only the first 30 suggestions are shown.") }
        var items: [DraftItem] = []
        for (i, v) in rawTasks.prefix(30).enumerated() {
            guard let o = v.object, let title = o["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                warnings.append("Suggestion \(i + 1) was skipped because it had no title."); continue
            }
            let t = String(title.prefix(200))
            let requested = o["durationMinutes"]?.int
            let duration = min(720, max(5, requested ?? RoughInputParser.defaultDuration(t)))
            if let r = requested, r != duration { warnings.append("\"\(t)\": duration adjusted to \(duration) min.") }
            let priority: PlanPriority
            switch o["priority"]?.string?.lowercased() {
            case "high", "urgent": priority = .high
            case "medium", "med", "normal": priority = .medium
            case "low": priority = .low
            default: priority = .none
            }
            let startText = o["start"]?.string
            let start = startText.flatMap { parse($0, planDate) }
            if startText != nil && start == nil { warnings.append("\"\(t)\": couldn't read the suggested time, left unscheduled.") }
            let subtasks = (o["subtasks"]?.array ?? []).compactMap { $0.string?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(20).map { String($0.prefix(200)) }
            let task = PlannerTask(id: "ai-\(i)", title: t, durationMinutes: duration, priority: priority,
                                   deadline: o["deadline"]?.string.flatMap { parse($0, planDate) },
                                   subtasks: Array(subtasks), notes: o["notes"]?.string.map { String($0.prefix(2000)) })
            items.append(DraftItem(task: task, slot: start.map { TimeWindow($0, $0.plusMinutes(duration)) }))
        }
        if items.isEmpty { throw InvalidResponse(message: "The AI response didn't contain any usable tasks.") }
        let checked = OfflinePlanner.recheck(items, busy: busy, availability: availability)
        if checked.contains(where: { $0.flags.contains(.overlapsExisting) || $0.flags.contains(.overlapsDraft) }) {
            warnings.append("Some suggested times overlap other tasks. They're marked below.")
        }
        return PlanDraft(source: .ai, items: OfflinePlanner.sortForDisplay(checked),
                         summary: root["summary"]?.string.map { String($0.prefix(500)) } ?? "AI-suggested plan",
                         warnings: warnings, modelName: root["model"]?.string.map { String($0.prefix(80)) })
    }

    static func parse(_ s: String, _ planDate: LocalDate) -> LocalDateTime? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let dt = LocalDateTime(iso: String(trimmed.prefix(16))) { return dt }
        let hm = trimmed.split(separator: ":").map { Int($0) }
        if hm.count >= 2, let h = hm[0], let m = hm[1], (0...23).contains(h), (0...59).contains(m) {
            return LocalDateTime(planDate, LocalTime(h, m))
        }
        return nil
    }
}
