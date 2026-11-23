import Foundation

public enum EditScope: Sendable { case all, thisOccurrence, thisAndFuture }

public struct SubtaskDraft: Equatable, Identifiable, Sendable {
    public var id: String
    /// Id of the stored subtask this edits, if any.
    public var existingId: String?
    public var title: String
    public var done: Bool
    public init(existingId: String? = nil, title: String, done: Bool = false) {
        self.id = existingId ?? UUID().uuidString; self.existingId = existingId; self.title = title; self.done = done
    }
}

public struct TaskDraft: Equatable, Sendable {
    public var title: String
    public var notes = ""
    public var listId: String?
    public var priority = 0
    public var starred = false
    public var dueDate: LocalDate?
    public var dueTime: LocalTime?
    public var rule: RecurrenceRule?
    public var reminderOffsets: [Int] = []
    public var estimatedMinutes: Int?
    public var subtasks: [SubtaskDraft] = []

    public init(title: String, notes: String = "", listId: String? = nil, priority: Int = 0, starred: Bool = false,
                dueDate: LocalDate? = nil, dueTime: LocalTime? = nil, rule: RecurrenceRule? = nil,
                reminderOffsets: [Int] = [], estimatedMinutes: Int? = nil, subtasks: [SubtaskDraft] = []) {
        self.title = title; self.notes = notes; self.listId = listId; self.priority = priority; self.starred = starred
        self.dueDate = dueDate; self.dueTime = dueTime; self.rule = rule; self.reminderOffsets = reminderOffsets
        self.estimatedMinutes = estimatedMinutes; self.subtasks = subtasks
    }

    /// Equality ignoring generated subtask row ids (used to detect "changed").
    public func sameContent(as o: TaskDraft) -> Bool {
        var a = self, b = o
        a.subtasks = a.subtasks.map { SubtaskDraft(existingId: $0.existingId ?? "new", title: $0.title, done: $0.done) }
        b.subtasks = b.subtasks.map { SubtaskDraft(existingId: $0.existingId ?? "new", title: $0.title, done: $0.done) }
        return a == b
    }
}

/// Snapshot of rows before a destructive change, so the UI can offer Undo.
public struct UndoToken: Sendable {
    public var tasks: [TaskItem] = []
    public var subtasks: [Subtask] = []
    public var occurrences: [Occurrence] = []
    public var createdTaskIds: [String] = []
}

public struct StarterList: Sendable { public let key: String; public let name: String; public let color: Int }

public let starterLists: [StarterList] = [
    .init(key: "personal", name: "Personal", color: 0xFF5C6BC0), .init(key: "work", name: "Work", color: 0xFF00897B),
    .init(key: "study", name: "Study", color: 0xFF8E24AA), .init(key: "fitness", name: "Fitness", color: 0xFFE53935),
    .init(key: "travel", name: "Travel", color: 0xFF039BE5), .init(key: "wishlist", name: "Wishlist", color: 0xFFF4511E),
    .init(key: "family", name: "Family events", color: 0xFFD81B60),
]

extension Array where Element: Identifiable, Element.ID == String {
    mutating func upsert(_ v: Element) {
        if let i = firstIndex(where: { $0.id == v.id }) { self[i] = v } else { append(v) }
    }
    func find(_ id: String) -> Element? { first { $0.id == id } }
}

/// All task/list mutations. Every write gets a fresh HLC version and this device's id, so sync
/// can resolve conflicts (see docs/SYNC.md). Mirrors the Android TaskRepository.
public struct TaskOperations: Sendable {
    public let clock: HybridLogicalClock
    public let deviceId: String
    public let nowMillis: @Sendable () -> Int64

    public init(clock: HybridLogicalClock, deviceId: String, nowMillis: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.clock = clock; self.deviceId = deviceId; self.nowMillis = nowMillis
    }

    func stamp<T: Versioned>(_ v: T) -> T { var x = v; x.version = clock.now(); x.deviceId = deviceId; return x }

    // MARK: create / edit

    @discardableResult
    public func create(_ d: TaskDraft, in db: inout Database, seriesParentId: String? = nil, completed: Bool = false) -> String {
        let id = UUID().uuidString
        var t = TaskItem(id: id, listId: d.listId, title: d.title.trimmingCharacters(in: .whitespacesAndNewlines),
                         createdAt: nowMillis(), version: clock.now(), deviceId: deviceId)
        apply(d, to: &t)
        t.seriesParentId = seriesParentId
        t.completed = completed
        if completed { t.completedAt = nowMillis() }
        db.tasks.append(t)
        writeSubtasks(taskId: id, d.subtasks, in: &db, keepIds: false)
        return id
    }

    func apply(_ d: TaskDraft, to t: inout TaskItem) {
        t.listId = d.listId
        t.title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.notes = d.notes
        t.priority = d.priority
        t.starred = d.starred
        t.dueDate = d.dueDate
        t.dueTime = d.dueDate == nil ? nil : d.dueTime
        t.rrule = d.dueDate == nil ? nil : d.rule?.format()
        t.reminderOffsets = d.dueDate == nil ? [] : Array(Set(d.reminderOffsets)).sorted()
        t.estimatedMinutes = d.estimatedMinutes
    }

    func writeSubtasks(taskId: String, _ drafts: [SubtaskDraft], in db: inout Database, keepIds: Bool) {
        let existing = db.subtasks.filter { $0.taskId == taskId && !$0.deleted }
        var keep = Set<String>()
        for (i, s) in drafts.enumerated() where !s.title.trimmingCharacters(in: .whitespaces).isEmpty {
            let sid = (keepIds ? s.existingId.flatMap { id in existing.contains { $0.id == id } ? id : nil } : nil) ?? UUID().uuidString
            keep.insert(sid)
            let title = s.title.trimmingCharacters(in: .whitespaces)
            if let old = existing.first(where: { $0.id == sid }), old.title == title, old.done == s.done, old.sortOrder == i { continue }
            db.subtasks.upsert(Subtask(id: sid, taskId: taskId, title: title, done: s.done, sortOrder: i, version: clock.now(), deviceId: deviceId))
        }
        for old in existing where !keep.contains(old.id) {
            var o = old; o.deleted = true; db.subtasks.upsert(stamp(o))
        }
    }

    public func draft(of id: String, in db: Database) -> TaskDraft? {
        guard let t = db.tasks.find(id), !t.deleted else { return nil }
        let subs = db.subtasks.filter { $0.taskId == id && !$0.deleted }.sorted { $0.sortOrder < $1.sortOrder }
        return TaskDraft(title: t.title, notes: t.notes, listId: t.listId, priority: t.priority, starred: t.starred,
                         dueDate: t.dueDate, dueTime: t.dueTime, rule: t.rule, reminderOffsets: t.reminderOffsets,
                         estimatedMinutes: t.estimatedMinutes,
                         subtasks: subs.map { SubtaskDraft(existingId: $0.id, title: $0.title, done: $0.done) })
    }

    /// Edits a task. Recurring scopes: this occurrence (EXDATE + standalone copy), this and future
    /// (split the series), or all. Alarm keys include the task id, so old reminders are cancelled
    /// and only the new task's are scheduled.
    public func update(_ id: String, _ d: TaskDraft, scope: EditScope = .all, occurrence: LocalDate? = nil, in db: inout Database) {
        guard var cur = db.tasks.find(id), !cur.deleted else { return }
        guard let rule = cur.rule, let start = cur.dueDate, let occ = occurrence, scope != .all else {
            let wasRecurring = cur.isRecurring
            apply(d, to: &cur)
            db.tasks.upsert(stamp(cur))
            writeSubtasks(taskId: id, d.subtasks, in: &db, keepIds: true)
            if wasRecurring { pruneOrphanCompletions(id, in: &db) }
            return
        }
        // The editor shows the series' start date. If the user left it alone, the edited copy keeps
        // this occurrence's own date; if they changed it, their date wins.
        let targetDate = (d.dueDate == nil || d.dueDate == start) ? occ : d.dueDate!
        if scope == .thisOccurrence {
            detachOccurrence(id, rule: rule, occ: occ, draft: d, date: targetDate, in: &db)
            return
        }
        let (old, newRule) = RecurrenceEngine.split(start, rule, at: occ)
        guard let oldRule = old else {
            apply(d, to: &cur); db.tasks.upsert(stamp(cur))
            writeSubtasks(taskId: id, d.subtasks, in: &db, keepIds: true)
            pruneOrphanCompletions(id, in: &db)
            return
        }
        cur.rrule = oldRule.format()
        db.tasks.upsert(stamp(cur))
        var future = d
        future.dueDate = targetDate
        if let r = d.rule {
            var normalised = r; normalised.end = rule.end; normalised.exDates = rule.exDates
            future.rule = normalised == rule ? newRule : r
        }
        let newId = create(future, in: &db, seriesParentId: id)
        let moved = Set(db.occurrences.filter { $0.taskId == id && !$0.deleted && $0.date >= occ }.map(\.date))
        moveCompletions(from: id, to: future.dueDate == occ ? newId : nil, dates: moved, in: &db)
    }

    /// Removes [occ] from the series and creates a standalone task on [date] with the edits.
    func detachOccurrence(_ id: String, rule: RecurrenceRule, occ: LocalDate, draft d: TaskDraft, date: LocalDate, in db: inout Database) {
        guard var cur = db.tasks.find(id) else { return }
        cur.rrule = rule.withExDate(occ).format()
        db.tasks.upsert(stamp(cur))
        var single = d; single.rule = nil; single.dueDate = date
        let wasDone = db.occurrences.contains { $0.taskId == id && $0.date == occ && $0.completed && !$0.deleted }
        create(single, in: &db, seriesParentId: id, completed: wasDone)
        moveCompletions(from: id, to: nil, dates: [occ], in: &db)
    }

    func pruneOrphanCompletions(_ id: String, in db: inout Database) {
        guard let t = db.tasks.find(id) else { return }
        for o in db.occurrences where o.taskId == id && !o.deleted && o.completed {
            let valid = t.dueDate.flatMap { s in t.rule.map { RecurrenceEngine.isOccurrence(s, $0, o.date) } } ?? false
            if !valid { var x = o; x.deleted = true; db.occurrences.upsert(stamp(x)) }
        }
    }

    func moveCompletions(from: String, to: String?, dates: Set<LocalDate>, in db: inout Database) {
        for o in db.occurrences where o.taskId == from && !o.deleted && dates.contains(o.date) {
            var x = o; x.deleted = true; db.occurrences.upsert(stamp(x))
            if let to, o.completed {
                db.occurrences.upsert(Occurrence(taskId: to, date: o.date, completed: true, completedAt: o.completedAt, version: clock.now(), deviceId: deviceId))
            }
        }
    }

    // MARK: completion

    public func setCompleted(_ id: String, occurrence: LocalDate?, completed: Bool, in db: inout Database) {
        guard var t = db.tasks.find(id), !t.deleted else { return }
        if t.isRecurring, let occ = occurrence {
            let oid = Occurrence.idFor(id, occ)
            let existing = db.occurrences.find(oid)
            var o = Occurrence(taskId: id, date: occ, completed: completed, completedAt: completed ? nowMillis() : nil,
                               version: clock.now(), deviceId: deviceId)
            o.seenDeleteVersion = existing.map { $0.deleted ? $0.version : $0.seenDeleteVersion } ?? 0
            db.occurrences.upsert(o)
        } else {
            t.completed = completed
            t.completedAt = completed ? nowMillis() : nil
            db.tasks.upsert(stamp(t))
        }
    }

    public func setSubtaskDone(_ id: String, done: Bool, in db: inout Database) {
        guard var s = db.subtasks.find(id) else { return }
        s.done = done
        db.subtasks.upsert(stamp(s))
    }

    // MARK: delete / undo

    public func delete(_ id: String, scope: EditScope = .all, occurrence: LocalDate? = nil, in db: inout Database) -> UndoToken? {
        guard var t = db.tasks.find(id), !t.deleted else { return nil }
        if let rule = t.rule, let start = t.dueDate, let occ = occurrence, scope != .all {
            let token = UndoToken(tasks: [t])
            let newRule = scope == .thisOccurrence ? rule.withExDate(occ) : RecurrenceEngine.split(start, rule, at: occ).0
            if let r = newRule { t.rrule = r.format(); db.tasks.upsert(stamp(t)) } else { tombstone(id, in: &db) }
            return token
        }
        let token = UndoToken(tasks: [t],
                              subtasks: db.subtasks.filter { $0.taskId == id && !$0.deleted },
                              occurrences: db.occurrences.filter { $0.taskId == id && !$0.deleted })
        tombstone(id, in: &db)
        return token
    }

    func tombstone(_ id: String, in db: inout Database) {
        if var t = db.tasks.find(id) { t.deleted = true; db.tasks.upsert(stamp(t)) }
        for s in db.subtasks where s.taskId == id && !s.deleted { var x = s; x.deleted = true; db.subtasks.upsert(stamp(x)) }
        for o in db.occurrences where o.taskId == id && !o.deleted { var x = o; x.deleted = true; db.occurrences.upsert(stamp(x)) }
    }

    /// Restores rows; records the tombstone version so sync treats it as an explicit restore.
    public func undo(_ token: UndoToken, in db: inout Database) {
        for t in token.tasks {
            var x = t; x.deleted = false; x.seenDeleteVersion = db.tasks.find(t.id)?.version ?? 0; db.tasks.upsert(stamp(x))
        }
        for s in token.subtasks {
            var x = s; x.deleted = false; x.seenDeleteVersion = db.subtasks.find(s.id)?.version ?? 0; db.subtasks.upsert(stamp(x))
        }
        for o in token.occurrences {
            var x = o; x.deleted = false; x.seenDeleteVersion = db.occurrences.find(o.id)?.version ?? 0; db.occurrences.upsert(stamp(x))
        }
        for id in token.createdTaskIds { tombstone(id, in: &db) }
    }

    // MARK: misc

    @discardableResult
    public func duplicate(_ id: String, in db: inout Database) -> String? {
        guard let t = db.tasks.find(id), !t.deleted else { return nil }
        let newId = UUID().uuidString
        var c = t
        c.id = newId; c.completed = false; c.completedAt = nil; c.seriesParentId = nil
        c.createdAt = nowMillis(); c.sortOrder = c.createdAt; c.seenDeleteVersion = 0
        db.tasks.append(stamp(c))
        for s in db.subtasks where s.taskId == id && !s.deleted {
            db.subtasks.append(Subtask(id: UUID().uuidString, taskId: newId, title: s.title, done: false, sortOrder: s.sortOrder, version: clock.now(), deviceId: deviceId))
        }
        return newId
    }

    public func move(_ id: String, to listId: String?, in db: inout Database) {
        guard var t = db.tasks.find(id) else { return }
        t.listId = listId; db.tasks.upsert(stamp(t))
    }

    public func setStarred(_ id: String, _ starred: Bool, in db: inout Database) {
        guard var t = db.tasks.find(id) else { return }
        t.starred = starred; db.tasks.upsert(stamp(t))
    }

    /// Moves a one-off task, or a single occurrence of a recurring task, to [newDate] (nil = undated).
    public func reschedule(_ id: String, occurrence: LocalDate?, to newDate: LocalDate?, in db: inout Database) {
        guard var t = db.tasks.find(id) else { return }
        if let rule = t.rule, let occ = occurrence, let d = draft(of: id, in: db) {
            detachOccurrence(id, rule: rule, occ: occ, draft: d, date: newDate ?? occ, in: &db)
            return
        }
        t.dueDate = newDate
        if newDate == nil { t.dueTime = nil; t.reminderOffsets = [] }
        db.tasks.upsert(stamp(t))
    }

    // MARK: lists

    @discardableResult
    public func createList(_ name: String, color: Int?, icon: String?, in db: inout Database) -> String {
        let id = UUID().uuidString
        let order = (db.lists.map(\.sortOrder).max() ?? 0) + 1
        db.lists.append(TaskList(id: id, name: name.trimmingCharacters(in: .whitespaces), color: color, icon: icon,
                                 sortOrder: order, version: clock.now(), deviceId: deviceId))
        return id
    }

    public func updateList(_ id: String, name: String, color: Int?, icon: String?, in db: inout Database) {
        guard var l = db.lists.find(id) else { return }
        l.name = name.trimmingCharacters(in: .whitespaces); l.color = color; l.icon = icon
        db.lists.upsert(stamp(l))
    }

    /// Deletes a list; its tasks move to the Inbox.
    public func deleteList(_ id: String, in db: inout Database) {
        for t in db.tasks where t.listId == id && !t.deleted { var x = t; x.listId = nil; db.tasks.upsert(stamp(x)) }
        if var l = db.lists.find(id) { l.deleted = true; db.lists.upsert(stamp(l)) }
    }

    public func addStarterLists(_ keys: Set<String>, in db: inout Database) {
        let existing = Set(db.lists.filter { !$0.deleted }.map { $0.name.lowercased() })
        for s in starterLists where keys.contains(s.key) && !existing.contains(s.name.lowercased()) {
            createList(s.name, color: s.color, icon: s.key, in: &db)
        }
    }

    public static func maxVersion(_ db: Database) -> Int64 {
        max(db.lists.map(\.version).max() ?? 0, db.tasks.map(\.version).max() ?? 0,
            db.subtasks.map(\.version).max() ?? 0, db.occurrences.map(\.version).max() ?? 0)
    }
}

extension Database {
    /// Inputs for the reminder planner.
    public func reminderTasks() -> [ReminderTask] {
        let done = Dictionary(grouping: occurrences.filter { $0.completed && !$0.deleted }, by: \.taskId).mapValues { Set($0.map(\.date)) }
        return tasks.map { t in
            let completed: Set<LocalDate> = t.isRecurring ? (done[t.id] ?? []) : (t.completed ? Set([t.dueDate].compactMap { $0 }) : [])
            return ReminderTask(taskId: t.id, title: t.title, startDate: t.dueDate, time: t.dueTime, rule: t.rule,
                                offsets: t.reminderOffsets, completedDates: completed, deleted: t.deleted)
        }
    }
}
