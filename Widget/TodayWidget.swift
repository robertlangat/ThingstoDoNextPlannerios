import AppIntents
import PlannerCore
import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
    struct Row: Identifiable, Hashable {
        let taskId: String
        let date: String
        let title: String
        let meta: String
        let done: Bool
        var id: String { taskId + "@" + date }
    }
    let date: Date
    let rows: [Row]
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), rows: [.init(taskId: "1", date: "", title: "Plan the week", meta: "09:00", done: false),
                                        .init(taskId: "2", date: "", title: "Call mum", meta: "", done: true)])
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) { completion(load()) }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        // Refresh just after midnight so "Today" rolls over; the app also reloads after every change.
        let tomorrow = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 60)
        completion(Timeline(entries: [load()], policy: .after(tomorrow)))
    }

    private func load() -> TodayEntry {
        let data = AppData(SharedStore.shared.load())
        let today = LocalDate.today()
        let todays = data.occurrences(from: today, to: today)
        let overdue = data.tasks.filter { !$0.isRecurring && !$0.completed && ($0.dueDate.map { $0 < today } ?? false) }
            .map { data.occurrence($0, $0.dueDate) }
        let rows = AppData.sort(overdue + todays).map { o -> TodayEntry.Row in
            var meta: [String] = []
            if o.isOverdue(today) { meta.append("Overdue") }
            if let t = o.time { meta.append(Fmt.time(t)) }
            if o.task.priority > 0 { meta.append(Fmt.priorityLabel(o.task.priority) + " " + Fmt.priorityMarks(o.task.priority)) }
            return .init(taskId: o.task.id, date: o.date?.isoString ?? "", title: o.task.title, meta: meta.joined(separator: " · "), done: o.completed)
        }
        return TodayEntry(date: Date(), rows: rows)
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private var limit: Int {
        switch family {
        case .systemSmall: return 3
        case .systemMedium: return 4
        default: return 10
        }
    }

    var body: some View {
        let open = entry.rows.filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(open == 0 ? "Today" : "Today · \(open) left").font(.headline)
                Spacer()
                Link(destination: URL(string: "thingstodonext://quickadd")!) {
                    Image(systemName: "plus.circle.fill").font(.title2)
                }
                .accessibilityLabel("Add task")
            }
            if entry.rows.isEmpty {
                Spacer()
                Text("Nothing due today 🎉").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.rows.prefix(limit)) { row in
                    HStack(spacing: 8) {
                        Button(intent: ToggleTaskIntent(taskId: row.taskId, date: row.date, done: !row.done)) {
                            Image(systemName: row.done ? "checkmark.circle.fill" : "circle").font(.title3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel((row.done ? "Reopen " : "Complete ") + row.title)
                        Link(destination: URL(string: "thingstodonext://task/\(row.taskId)/\(row.date)")!) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.title).font(.subheadline).lineLimit(family == .systemSmall ? 1 : 2)
                                    .strikethrough(row.done).foregroundStyle(row.done ? .secondary : .primary)
                                if !row.meta.isEmpty && family != .systemSmall {
                                    Text(row.meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                if entry.rows.count > limit { Text("+\(entry.rows.count - limit) more").font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodayWidget", provider: TodayProvider()) { TodayWidgetView(entry: $0) }
            .configurationDisplayName("Today's tasks")
            .description("Today's tasks with checkboxes and quick add.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ThingsToDoNextWidgets: WidgetBundle {
    var body: some Widget { TodayWidget() }
}
