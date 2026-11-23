import Foundation
import PlannerCore
import SwiftUI
import WidgetKit

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var actionLabel: String?
    var action: (() -> Void)?
    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

/// App-wide state and task actions. All writes go through SharedStore, then refresh reminders,
/// the widget, the watch and (if enabled) Drive sync.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var db = Database()
    @Published private(set) var data = AppData(Database())
    @Published var today = LocalDate.today()
    @Published var toast: Toast?
    /// Deep links from notifications / widget.
    @Published var openTaskRequest: (id: String, date: LocalDate?)?
    @Published var quickAddRequested = false

    let settings: AppSettings
    let store = SharedStore.shared
    lazy var sync = SyncManager(model: self)
    lazy var watch = PhoneWatchBridge(model: self)

    init(settings: AppSettings) {
        self.settings = settings
        reload()
    }

    func reload() {
        db = store.load()
        data = AppData(db)
        today = LocalDate.today()
    }

    /// Apply a mutation, then refresh everything that depends on data.
    @discardableResult
    func perform<T>(fromSync: Bool = false, _ body: (inout Database, TaskOperations) -> T) -> T {
        let result = store.mutate(body)
        reload()
        afterChange(fromSync: fromSync)
        return result
    }

    func afterChange(fromSync: Bool = false) {
        rescheduleReminders()
        WidgetCenter.shared.reloadAllTimelines()
        watch.publish()
        if !fromSync && settings.driveSignedIn && settings.autoSync { sync.scheduleSoon() }
    }

    func rescheduleReminders() {
        let db = self.db
        let enabled = settings.remindersEnabled && settings.remindersOnThisDevice
        let allDay = settings.allDayTime
        let silent = settings.sound == .silent
        Task { await NotificationScheduler.reconcile(db: db, enabled: enabled, allDayTime: allDay, silent: silent) }
    }

    func show(_ text: String, undo: (() -> Void)? = nil) {
        toast = Toast(text: text, actionLabel: undo == nil ? nil : "Undo", action: undo)
    }

    // MARK: actions (with undo where it matters)

    func toggle(_ o: TaskOccurrence) {
        let nowDone = !o.completed
        perform { db, ops in ops.setCompleted(o.task.id, occurrence: o.date, completed: nowDone, in: &db) }
        show((nowDone ? "Completed “" : "Reopened “") + o.task.title + "”") { [weak self] in
            self?.perform { db, ops in ops.setCompleted(o.task.id, occurrence: o.date, completed: o.completed, in: &db) }
        }
    }

    func delete(_ o: TaskOccurrence, scope: EditScope) {
        guard let token = perform({ db, ops in ops.delete(o.task.id, scope: scope, occurrence: o.date, in: &db) }) else { return }
        show("Deleted “\(o.task.title)”") { [weak self] in self?.perform { db, ops in ops.undo(token, in: &db) } }
    }

    func star(_ o: TaskOccurrence) { perform { db, ops in ops.setStarred(o.task.id, !o.task.starred, in: &db) } }

    func duplicate(_ o: TaskOccurrence) {
        guard let id = perform({ db, ops in ops.duplicate(o.task.id, in: &db) }) else { return }
        show("Duplicated “\(o.task.title)”") { [weak self] in self?.perform { db, ops in _ = ops.delete(id, in: &db) } }
    }

    func move(_ o: TaskOccurrence, to listId: String?) {
        let previous = o.task.listId
        perform { db, ops in ops.move(o.task.id, to: listId, in: &db) }
        let name = listId.flatMap { data.listsById[$0]?.name } ?? "Inbox"
        show("Moved to \(name)") { [weak self] in self?.perform { db, ops in ops.move(o.task.id, to: previous, in: &db) } }
    }

    func reschedule(_ o: TaskOccurrence, to date: LocalDate?) {
        perform { db, ops in ops.reschedule(o.task.id, occurrence: o.date, to: date, in: &db) }
        show(date == nil ? "Removed date" : "Rescheduled to \(Fmt.date(date!, today: today))")
    }

    func quickAdd(_ title: String, date: LocalDate?, listId: String?) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let id = perform { db, ops in ops.create(TaskDraft(title: t, listId: listId, dueDate: date), in: &db) }
        show("Added “\(t)”") { [weak self] in self?.perform { db, ops in _ = ops.delete(id, in: &db) } }
    }

    func setSubtaskDone(_ id: String, _ done: Bool) { perform { db, ops in ops.setSubtaskDone(id, done: done, in: &db) } }

    @discardableResult
    func createList(_ name: String, color: Int?, icon: String?) -> String {
        perform { db, ops in ops.createList(name, color: color, icon: icon, in: &db) }
    }

    func updateList(_ id: String, name: String, color: Int?, icon: String?) {
        perform { db, ops in ops.updateList(id, name: name, color: color, icon: icon, in: &db) }
    }

    func deleteList(_ id: String) {
        perform { db, ops in ops.deleteList(id, in: &db) }
        show("List deleted. Its tasks moved to Inbox.")
    }

    func addStarterLists(_ keys: Set<String>) {
        perform { db, ops in ops.addStarterLists(keys, in: &db) }
        settings.starterOffered = true
    }

    func snooze(taskId: String, date: LocalDate) {
        NotificationScheduler.snooze(taskId: taskId, date: date, minutes: settings.snoozeMinutes)
        rescheduleReminders()
    }

    /// Rows for the widget and the watch: today's occurrences plus overdue one-offs.
    func todayRows() -> [TaskOccurrence] {
        let todays = data.occurrences(from: today, to: today)
        let overdue = data.tasks.filter { !$0.isRecurring && !$0.completed && ($0.dueDate.map { $0 < today } ?? false) }
            .map { data.occurrence($0, $0.dueDate) }
        return AppData.sort(overdue + todays)
    }
}
