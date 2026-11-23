import Foundation
import PlannerCore

/// App Store screenshot mode, used only by CI (`-ScreenshotScene today|focus|calendar|planner|editor|mine`).
/// It uses a separate demo database, shows no ads and no permission prompts, and opens the requested
/// screen. Normal launches never pass this argument.
enum ScreenshotMode {
    static var scene: String? { UserDefaults.standard.string(forKey: "ScreenshotScene") }
    static var isOn: Bool { scene != nil }

    static let reportId = "demo-report"

    static func demoDatabase(today t: LocalDate = .today()) -> Database {
        let ops = TaskOperations(clock: HybridLogicalClock(), deviceId: "demo")
        var db = Database()
        let work = ops.createList("Work", color: 0xFF00897B, icon: "work", in: &db)
        let personal = ops.createList("Personal", color: 0xFF5C6BC0, icon: "personal", in: &db)
        let study = ops.createList("Study", color: 0xFF8E24AA, icon: "study", in: &db)
        let fitness = ops.createList("Fitness", color: 0xFFE53935, icon: "fitness", in: &db)
        let family = ops.createList("Family events", color: 0xFFD81B60, icon: "family", in: &db)

        func add(_ d: TaskDraft, done: Bool = false) -> String {
            let id = ops.create(d, in: &db)
            if done { ops.setCompleted(id, occurrence: d.rule == nil ? nil : d.dueDate, completed: true, in: &db) }
            return id
        }
        let standup = add(TaskDraft(title: "Team stand-up", listId: work, dueDate: t, dueTime: LocalTime(9, 30),
                                    rule: RecurrenceRule(.WEEKDAYS), reminderOffsets: [10]))
        ops.setCompleted(standup, occurrence: t, completed: true, in: &db)
        let report = add(TaskDraft(title: "Finish quarterly report", notes: "Share the final PDF with the team before Friday.",
                                   listId: work, priority: 3, starred: true, dueDate: t, dueTime: LocalTime(11, 0),
                                   reminderOffsets: [0, 30], estimatedMinutes: 90,
                                   subtasks: [SubtaskDraft(title: "Collect sales figures", done: true),
                                              SubtaskDraft(title: "Draft the summary", done: true),
                                              SubtaskDraft(title: "Review with Amina")]))
        if let i = db.tasks.firstIndex(where: { $0.id == report }) {
            let old = db.tasks[i].id
            db.tasks[i].id = reportId
            for j in db.subtasks.indices where db.subtasks[j].taskId == old { db.subtasks[j].taskId = reportId }
        }
        _ = add(TaskDraft(title: "Pay electricity bill", listId: personal, priority: 3, dueDate: t, reminderOffsets: [0]))
        _ = add(TaskDraft(title: "Revise chapter 4 for exam", listId: study, priority: 2, dueDate: t, dueTime: LocalTime(17, 30),
                          reminderOffsets: [15], estimatedMinutes: 60))
        _ = add(TaskDraft(title: "Gym - leg day", listId: fitness, dueDate: t, dueTime: LocalTime(19, 0),
                          rule: RecurrenceRule(.WEEKLY), estimatedMinutes: 60))
        _ = add(TaskDraft(title: "Call Mum", listId: personal, dueDate: t), done: true)
        _ = add(TaskDraft(title: "Read 20 pages", listId: study, dueDate: t.plusDays(-10), dueTime: LocalTime(21, 0),
                          rule: RecurrenceRule(.DAILY), reminderOffsets: [0]))
        _ = add(TaskDraft(title: "Renew car insurance", listId: personal, priority: 2, dueDate: t.plusDays(-1)))
        _ = add(TaskDraft(title: "Buy groceries", listId: personal, dueDate: t.plusDays(1), dueTime: LocalTime(18, 0),
                          estimatedMinutes: 45, subtasks: [SubtaskDraft(title: "Milk"), SubtaskDraft(title: "Eggs"), SubtaskDraft(title: "Bread")]))
        _ = add(TaskDraft(title: "Dentist appointment", listId: personal, dueDate: t.plusDays(2), dueTime: LocalTime(10, 0), reminderOffsets: [60]))
        _ = add(TaskDraft(title: "Sarah's birthday", listId: family, starred: true, dueDate: t.plusDays(4),
                          rule: RecurrenceRule(.YEARLY), reminderOffsets: [1440]))
        _ = add(TaskDraft(title: "Book flights to Mombasa", listId: personal, priority: 1, dueDate: t.plusDays(6)))
        _ = add(TaskDraft(title: "Client presentation", listId: work, priority: 3, dueDate: t.plusDays(8), dueTime: LocalTime(14, 0)))
        _ = add(TaskDraft(title: "Water the plants", listId: personal, dueDate: t.plusDays(-3), rule: RecurrenceRule(.DAILY, interval: 3)))
        _ = add(TaskDraft(title: "Pay rent", listId: personal, priority: 3, dueDate: LocalDate(t.year, t.month, 1), rule: RecurrenceRule(.MONTHLY)))
        _ = add(TaskDraft(title: "Plan weekend hike", listId: fitness, starred: true))
        _ = add(TaskDraft(title: "Mock exam", listId: study, priority: 2, dueDate: t.plusDays(12), dueTime: LocalTime(9, 0)))
        return db
    }

    /// The prompt typed into the planner for its screenshot.
    static let plannerPrompt = "Tomorrow I have three hours after work. Prepare slides for the client presentation, revise chapter 5 and do the laundry."
}
