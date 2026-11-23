import Foundation
import PlannerCore

/// Talks to the planner backend (the same Node service the Android app uses). The provider key
/// lives on the server; the user approves the exact payload before it is sent.
enum AIPlannerClient {
    static func payload(input: String, date: LocalDate, availability: [TimeWindow], busy: [BusyBlock], shareTitles: Bool) -> JSONValue {
        .object([
            "input": .string(String(input.prefix(4000))),
            "date": .string(date.isoString),
            "timezone": .string(TimeZone.current.identifier),
            "availability": .array(availability.map { .object(["start": .string($0.start.description), "end": .string($0.end.description)]) }),
            "busy": .array(busy.map { .object(["start": .string($0.window.start.description), "end": .string($0.window.end.description),
                                               "title": .string(shareTitles ? $0.title : "Busy")]) }),
        ])
    }

    static func plan(backend: String, payload: JSONValue, date: LocalDate, busy: [BusyBlock], availability: [TimeWindow]) async -> Result<PlanDraft, Error> {
        let base = backend.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return .failure(SyncError.message("No AI backend is configured. Set one in Settings → AI planner, or use the offline planner.")) }
        guard base.hasPrefix("https://") || base.hasPrefix("http://localhost") || base.hasPrefix("http://127.0.0.1"),
              let url = URL(string: base + "/v1/plan") else {
            return .failure(SyncError.message("The AI backend URL must use https://."))
        }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = Bundle.main.object(forInfoDictionaryKey: "AIAppToken") as? String, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = Data(payload.encodedString().utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 { return .failure(SyncError.message("The AI planner is busy. Try again shortly, or use the offline planner.")) }
            guard (200..<300).contains(code) else { return .failure(SyncError.message("The AI planner is unavailable right now (\(code)). Your tasks are unchanged.")) }
            return .success(try AIPlanValidator.validate(data, planDate: date, busy: busy, availability: availability))
        } catch let e as AIPlanValidator.InvalidResponse {
            return .failure(e)
        } catch let e as URLError where e.code == .timedOut {
            return .failure(SyncError.message("The AI planner took too long to answer. Try again or use the offline planner."))
        } catch {
            return .failure(SyncError.message("Couldn't reach the AI planner. Check your connection or use the offline planner."))
        }
    }
}

enum PlannerMode: String, CaseIterable, Identifiable { case offline = "Offline planner", ai = "AI planner"; var id: String { rawValue } }

@MainActor
final class PlannerModel: ObservableObject {
    @Published var input = ""
    @Published var date = LocalDate.today()
    @Published var start = LocalTime(17, 30)
    @Published var end = LocalTime(19, 30)
    @Published var includeUndated = true
    @Published var shareBusyTitles = false
    @Published var mode = PlannerMode.offline
    @Published var loading = false
    @Published var draft: PlanDraft?
    @Published var error: String?
    @Published var pendingPayload: String?
    private var payloadValue: JSONValue?

    private func busy(_ model: AppModel) -> [BusyBlock] {
        model.data.occurrences(from: date, to: date).filter { !$0.completed && $0.time != nil }.map {
            let s = LocalDateTime(date, $0.time!)
            return BusyBlock(title: $0.task.title, window: TimeWindow(s, s.plusMinutes($0.task.estimatedMinutes ?? 30)))
        }
    }

    private var availability: [TimeWindow] { [TimeWindow.on(date, from: start, to: end)] }

    private func applyHint() {
        guard let h = RoughInputParser.parse(input, today: .today()).availability else { return }
        date = h.date
        if let s = h.start { start = s }
        if let m = h.minutes { end = LocalTime(minutes: min(start.minutes + m, 24 * 60 - 1)) }
    }

    func planOffline(_ model: AppModel) {
        applyHint()
        let parsed = RoughInputParser.parse(input, today: .today()).tasks
        let existing: [PlannerTask] = includeUndated ? model.data.tasks.filter { t in
            !t.isRecurring && !t.completed && (t.dueDate == nil || (t.dueDate == date && t.dueTime == nil))
        }.map { t in
            PlannerTask(id: "existing:" + t.id, title: t.title, durationMinutes: t.estimatedMinutes ?? RoughInputParser.defaultDuration(t.title),
                        priority: PlanPriority(rawValue: t.priority) ?? .none,
                        deadline: t.dueDate.map { LocalDateTime($0, LocalTime(23, 59)) }, notes: t.notes.isEmpty ? nil : t.notes)
        } : []
        guard !(parsed.isEmpty && existing.isEmpty) else { error = "Type a goal or a few tasks first (one per line works well)."; return }
        error = nil
        draft = OfflinePlanner.plan(PlanRequest(tasks: parsed + existing, availability: availability, busy: busy(model)))
    }

    func prepareAI(_ model: AppModel) {
        applyHint()
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Describe your goal or paste your tasks first."; return }
        let p = AIPlannerClient.payload(input: input, date: date, availability: availability, busy: busy(model), shareTitles: shareBusyTitles)
        payloadValue = p
        pendingPayload = p.encodedString(sorted: true)
        error = nil
    }

    func sendAI(_ model: AppModel) async {
        guard let p = payloadValue else { return }
        pendingPayload = nil
        loading = true
        let result = await AIPlannerClient.plan(backend: model.settings.aiBackendURL, payload: p, date: date, busy: busy(model), availability: availability)
        loading = false
        switch result {
        case .success(let d): draft = d
        case .failure(let e): error = (e as? LocalizedError)?.errorDescription ?? "The AI planner failed."
        }
    }

    func edit(_ id: String, model: AppModel, _ change: (inout DraftItem) -> Void) {
        guard var d = draft, let i = d.items.firstIndex(where: { $0.id == id }) else { return }
        change(&d.items[i])
        d.items = OfflinePlanner.recheck(d.items, busy: busy(model), availability: availability)
        draft = d
    }

    /// Saves accepted items; existing tasks are rescheduled rather than duplicated.
    func save(_ model: AppModel) -> Int {
        guard let d = draft else { return 0 }
        let accepted = d.items.filter(\.accepted)
        let planDate = date
        model.perform { db, ops in
            for item in accepted {
                let day = item.slot?.start.date ?? planDate
                let time = item.slot?.start.time
                if item.task.id.hasPrefix("existing:") {
                    let id = String(item.task.id.dropFirst("existing:".count))
                    guard var draft = ops.draft(of: id, in: db) else { continue }
                    draft.dueDate = day; draft.dueTime = time ?? draft.dueTime; draft.estimatedMinutes = item.task.durationMinutes
                    ops.update(id, draft, in: &db)
                } else {
                    var notes = item.task.notes ?? ""
                    if d.source == .ai { notes += (notes.isEmpty ? "" : "\n\n") + "Suggested by the AI planner." }
                    ops.create(TaskDraft(title: item.task.title, notes: notes, priority: item.task.priority.rawValue, dueDate: day, dueTime: time,
                                         estimatedMinutes: item.task.durationMinutes,
                                         subtasks: item.task.subtasks.map { SubtaskDraft(title: $0) }), in: &db)
                }
            }
        }
        draft = nil
        input = ""
        return accepted.count
    }
}
