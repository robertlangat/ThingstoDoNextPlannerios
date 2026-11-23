import Foundation
import PlannerCore
import UserNotifications

/// Keeps pending local notifications in step with the database.
/// - Request identifiers are the deterministic alarm keys (`taskId@date#offset`), so adding the same
///   key replaces it: edits, snoozes, restores and syncs can't create duplicates.
/// - iOS allows 64 pending notifications per app; the soonest 60 are kept and topped up whenever the
///   app runs, on background refresh and at midnight.
/// - Triggers use floating calendar components, so a 09:00 reminder stays at 09:00 local after a
///   time-zone change; the schedule is also rebuilt on time-zone/clock changes.
/// - iOS persists pending notifications across reboots, so nothing extra is needed after restart.
enum NotificationScheduler {
    static let category = "TASK_REMINDER"
    static let completeAction = "COMPLETE"
    static let snoozeAction = "SNOOZE"
    private static let snoozeKey = "snoozes"

    static func registerCategories(snoozeMinutes: Int) {
        let complete = UNNotificationAction(identifier: completeAction, title: "Complete", options: [])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze \(snoozeMinutes) min", options: [])
        let cat = UNNotificationCategory(identifier: category, actions: [complete, snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks only when the user turns reminders on or adds one.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        let status = await authorizationStatus()
        if status == .notDetermined {
            return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    // MARK: snoozes (per device)

    static func snoozes() -> [Snooze] {
        let raw = AppGroup.defaults.dictionary(forKey: snoozeKey) as? [String: Double] ?? [:]
        return raw.compactMap { key, until in
            let parts = key.split(separator: "@")
            guard parts.count == 2, let date = LocalDate(iso: String(parts[1])) else { return nil }
            return Snooze(taskId: String(parts[0]), date: date, until: Date(timeIntervalSince1970: until))
        }
    }

    static func snooze(taskId: String, date: LocalDate, minutes: Int) {
        var raw = AppGroup.defaults.dictionary(forKey: snoozeKey) as? [String: Double] ?? [:]
        raw = raw.filter { $0.value > Date().addingTimeInterval(-86400).timeIntervalSince1970 }
        raw["\(taskId)@\(date.isoString)"] = Date().addingTimeInterval(TimeInterval(minutes * 60)).timeIntervalSince1970
        AppGroup.defaults.set(raw, forKey: snoozeKey)
    }

    // MARK: reconcile

    static func reconcile(db: Database, enabled: Bool, allDayTime: LocalTime, silent: Bool) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.content.categoryIdentifier == category }
        let status = await authorizationStatus()
        let allowed = status == .authorized || status == .provisional || status == .ephemeral
        guard enabled, allowed else {
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            return
        }
        let desired = ReminderPlanner.desired(tasks: db.reminderTasks(), snoozes: snoozes(), now: Date(), tz: .current,
                                              allDayTime: allDayTime, missedGrace: 0, maxAlarms: 60)
        var existing: [String: Date] = [:]
        for r in pending {
            if let t = r.trigger as? UNCalendarNotificationTrigger, let next = t.nextTriggerDate() { existing[r.identifier] = next }
        }
        let plan = ReminderPlanner.diff(desired, existing: existing)
        center.removePendingNotificationRequests(withIdentifiers: Array(plan.cancel))
        let byId = Dictionary(db.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for a in plan.schedule {
            let content = UNMutableNotificationContent()
            content.title = a.title
            var body = a.occurrenceDate == LocalDate.today() ? "Today" : Fmt.date(a.occurrenceDate)
            if let t = byId[a.taskId]?.dueTime { body += " · " + Fmt.time(t) }
            if byId[a.taskId]?.isRecurring == true { body += " · repeats" }
            if a.isSnooze { body += " · snoozed" }
            content.body = body
            content.sound = silent ? nil : .default
            content.categoryIdentifier = category
            content.threadIdentifier = "\(a.taskId)@\(a.occurrenceDate.isoString)"
            content.userInfo = ["taskId": a.taskId, "date": a.occurrenceDate.isoString, "key": a.key]
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: a.fireAt)
            let req = UNNotificationRequest(identifier: a.key, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(req)
        }
    }
}
