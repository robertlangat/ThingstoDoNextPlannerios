import PlannerCore
import SwiftUI
import WatchConnectivity

@main
struct ThingsToDoNextWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchRoot().environmentObject(model) }
    }
}

/// Watch-side state. Receives the phone's latest payload (application context) and sends
/// completions with transferUserInfo, which WatchConnectivity queues until the phone is reachable.
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    @Published var payload: WatchPayload?
    @Published var pending: Set<String> = []
    @Published var reachable = false
    private let defaults = UserDefaults.standard

    override init() {
        super.init()
        if let d = defaults.data(forKey: "payload") { payload = WatchPayload.decode(d) }
        pending = Set(defaults.stringArray(forKey: "pending") ?? [])
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func isDone(_ t: WatchTask) -> Bool { t.done || pending.contains(t.id) }

    func complete(_ t: WatchTask) {
        pending.insert(t.id)
        defaults.set(Array(pending), forKey: "pending")
        var info: [String: Any] = ["complete": t.taskId]
        if let d = t.date { info["date"] = d }
        WCSession.default.transferUserInfo(info)
    }

    func refresh() {
        let s = WCSession.default
        if let d = s.receivedApplicationContext["payload"] as? Data { apply(d) }
        if s.isReachable { s.sendMessage(["refresh": true], replyHandler: nil, errorHandler: nil) }
    }

    private func apply(_ data: Data) {
        guard let p = WatchPayload.decode(data) else { return }
        let confirmed = Set((p.today + p.upcoming).filter(\.done).map(\.id))
        payload = p
        pending.subtract(confirmed)
        defaults.set(data, forKey: "payload")
        defaults.set(Array(pending), forKey: "pending")
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.reachable = session.isReachable; self.refresh() }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.reachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let d = context["payload"] as? Data else { return }
        DispatchQueue.main.async { self.apply(d) }
    }
}

struct WatchRoot: View {
    @EnvironmentObject private var model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                if let p = model.payload {
                    Section("Today") {
                        if p.today.isEmpty { Text("Nothing due today").foregroundStyle(.secondary) }
                        ForEach(p.today) { t in
                            let done = model.isDone(t)
                            Button { if !done { model.complete(t) } } label: {
                                HStack {
                                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(Fmt.priorityMarks(t.priority) + (t.priority > 0 ? " " : "") + t.title)
                                            .strikethrough(done).lineLimit(2)
                                        let meta = [t.overdue ? "Overdue" : nil, t.time].compactMap { $0 }.joined(separator: " · ")
                                        if !meta.isEmpty { Text(meta).font(.caption2).foregroundStyle(t.overdue ? .red : .secondary) }
                                    }
                                }
                            }
                            .accessibilityLabel((done ? "Completed: " : "Complete ") + t.title)
                        }
                    }
                    if !p.upcoming.isEmpty {
                        Section("Upcoming deadlines") {
                            ForEach(p.upcoming) { t in
                                VStack(alignment: .leading) {
                                    Text(Fmt.priorityMarks(t.priority) + (t.priority > 0 ? " " : "") + t.title).lineLimit(2)
                                    if let time = t.time { Text(time).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    Section {
                        let status = ["Updated " + p.updatedAt.formatted(date: .omitted, time: .shortened),
                                      model.reachable ? nil : "phone not connected",
                                      model.pending.isEmpty ? nil : "\(model.pending.count) waiting to sync"].compactMap { $0 }
                        Text(status.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        Button("Refresh") { model.refresh() }
                    }
                } else {
                    Text("Open the iPhone app to load your tasks.").multilineTextAlignment(.center)
                    Button("Refresh") { model.refresh() }
                }
            }
            .navigationTitle("Things to Do")
        }
    }
}

enum Fmt {
    static func priorityMarks(_ p: Int) -> String { ["", "!", "!!", "!!!"][max(0, min(3, p))] }
}
