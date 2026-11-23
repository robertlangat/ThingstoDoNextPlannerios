import Foundation
import PlannerCore
import WatchConnectivity

/// Sends today's tasks and upcoming deadlines to the Apple Watch (application context = latest
/// state wins) and receives completions as queued user-info transfers, which WatchConnectivity
/// delivers even if the phone was unreachable when the user tapped.
@MainActor
final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func publish() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled, let model else { return }
        let today = model.today
        let toWatch: (TaskOccurrence) -> WatchTask = { o in
            WatchTask(taskId: o.task.id, date: o.date?.isoString, title: o.task.title,
                      time: o.time.map(Fmt.time) ?? o.date.flatMap { $0 == today ? nil : Fmt.date($0, today: today) },
                      done: o.completed, priority: o.task.priority, overdue: o.isOverdue(today))
        }
        let upcoming = AppData.sort(model.data.occurrences(from: today.plusDays(1), to: today.plusDays(7)).filter { !$0.completed }).prefix(15)
        let payload = WatchPayload(updatedAt: Date(), today: model.todayRows().map(toWatch), upcoming: upcoming.map(toWatch))
        try? WCSession.default.updateApplicationContext(["payload": payload.encoded()])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.publish() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let taskId = userInfo["complete"] as? String else { return }
        let date = (userInfo["date"] as? String).flatMap { LocalDate(iso: $0) }
        Task { @MainActor in
            self.model?.perform { db, ops in ops.setCompleted(taskId, occurrence: date, completed: true, in: &db) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["refresh"] != nil { Task { @MainActor in self.publish() } }
    }
}
