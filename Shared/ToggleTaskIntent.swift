import AppIntents
import Foundation
import PlannerCore
import UserNotifications
import WidgetKit

/// Completes / reopens a task (or one occurrence) from the interactive widget.
struct ToggleTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete task"
    static var description = IntentDescription("Marks a task as done or not done.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Task ID") var taskId: String
    @Parameter(title: "Date") var date: String
    @Parameter(title: "Done") var done: Bool

    init() {}

    init(taskId: String, date: String, done: Bool) {
        self.taskId = taskId
        self.date = date
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        let occurrence = LocalDate(iso: date)
        SharedStore.shared.mutate { db, ops in
            ops.setCompleted(taskId, occurrence: occurrence, completed: done, in: &db)
        }
        if done {
            // Cancel this occurrence's pending reminders right away; the app reconciles the rest.
            let prefix = "\(taskId)@\(date)"
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
        AppGroup.defaults.set(Date().timeIntervalSince1970, forKey: "externalChangeAt")
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
