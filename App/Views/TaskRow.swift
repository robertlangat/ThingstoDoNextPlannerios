import EventKit
import EventKitUI
import PlannerCore
import SwiftUI

struct PriorityBadge: View {
    let priority: Int
    var body: some View {
        if priority > 0 {
            Text(Fmt.priorityMarks(priority))
                .font(.caption.bold())
                .foregroundStyle(Fmt.priorityColor(priority))
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Fmt.priorityColor(priority)))
                .accessibilityLabel("\(Fmt.priorityLabel(priority)) priority")
        }
    }
}

struct ListDot: View {
    let color: Int64?
    var size: CGFloat = 10
    var body: some View { Circle().fill(Fmt.color(color)).frame(width: size, height: size).accessibilityHidden(true) }
}

/// Holds the task-action sheets that rows can trigger (shared by Tasks and Calendar).
final class RowActionState: ObservableObject {
    @Published var move: TaskOccurrence?
    @Published var reschedule: TaskOccurrence?
    @Published var deleteRecurring: TaskOccurrence?
    @Published var calendarExport: TaskOccurrence?
}

struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var actions: RowActionState
    let item: TaskOccurrence
    var showDate = true
    let onOpen: (TaskOccurrence) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { model.toggle(item) } label: {
                Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(item.completed ? Color.accentColor : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.completed ? "Reopen \(item.task.title)" : "Complete \(item.task.title)")
            .accessibilityValue(item.completed ? "Completed" : "Not completed")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    PriorityBadge(priority: item.task.priority)
                    Text(item.task.title)
                        .strikethrough(item.completed)
                        .foregroundStyle(item.completed ? .secondary : .primary)
                        .lineLimit(2)
                }
                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen(item) }
            .accessibilityAddTraits(.isButton)

            Button { model.star(item) } label: {
                Image(systemName: item.task.starred ? "star.fill" : "star")
                    .foregroundStyle(item.task.starred ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.task.starred ? "Unstar" : "Star")
        }
        .swipeActions(edge: .leading) {
            Button { model.toggle(item) } label: { Label(item.completed ? "Reopen" : "Complete", systemImage: "checkmark") }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
            Button { actions.reschedule = item } label: { Label("Reschedule", systemImage: "calendar") }.tint(.orange)
        }
        .contextMenu {
            Button { actions.reschedule = item } label: { Label("Reschedule", systemImage: "calendar") }
            Button { actions.move = item } label: { Label("Move to list", systemImage: "folder") }
            Button { model.duplicate(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            if item.date != nil { Button { actions.calendarExport = item } label: { Label("Add to device calendar", systemImage: "calendar.badge.plus") } }
            Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func delete() {
        if item.task.isRecurring { actions.deleteRecurring = item } else { model.delete(item, scope: .all) }
    }

    @ViewBuilder private var metaLine: some View {
        let today = model.today
        let parts: [String] = {
            var p: [String] = []
            if showDate, let d = item.date { p.append(Fmt.date(d, today: today)) }
            if let t = item.time { p.append(Fmt.time(t)) } else if showDate && item.date != nil { p.append("All day") }
            if item.subtasksTotal > 0 { p.append("\(item.subtasksDone)/\(item.subtasksTotal) subtasks") }
            if let l = item.list { p.append(l.name) }
            return p
        }()
        if !parts.isEmpty || item.task.isRecurring || !item.task.reminderOffsets.isEmpty {
            HStack(spacing: 4) {
                if let l = item.list { ListDot(color: l.color, size: 8) }
                Text(parts.joined(separator: " · ")).lineLimit(1)
                if item.isOverdue(today) { Text("Overdue").bold() }
                if item.task.isRecurring { Image(systemName: "repeat").accessibilityLabel("Repeats") }
                if !item.task.reminderOffsets.isEmpty { Image(systemName: "bell").accessibilityLabel("Has reminder") }
            }
            .font(.caption)
            .foregroundStyle(item.isOverdue(today) ? Color.red : .secondary)
        }
    }
}

/// Sheets and dialogs for row actions.
struct RowActionSheets: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var actions: RowActionState
    @State private var pickDate = Date()

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Move to list", isPresented: Binding(get: { actions.move != nil }, set: { if !$0 { actions.move = nil } }), titleVisibility: .visible) {
                if let item = actions.move {
                    Button("Inbox") { model.move(item, to: nil) }
                    ForEach(model.data.lists) { l in Button(l.name) { model.move(item, to: l.id) } }
                }
            }
            .confirmationDialog("Delete repeating task", isPresented: Binding(get: { actions.deleteRecurring != nil }, set: { if !$0 { actions.deleteRecurring = nil } }), titleVisibility: .visible) {
                if let item = actions.deleteRecurring {
                    Button("This occurrence", role: .destructive) { model.delete(item, scope: .thisOccurrence) }
                    Button("This and future occurrences", role: .destructive) { model.delete(item, scope: .thisAndFuture) }
                    Button("All occurrences", role: .destructive) { model.delete(item, scope: .all) }
                }
            }
            .sheet(item: $actions.reschedule) { item in
                NavigationStack {
                    Form {
                        if item.task.isRecurring { Text("Only this occurrence moves; the rest of the series stays.").font(.footnote) }
                        let today = model.today
                        Section {
                            Button("Today") { model.reschedule(item, to: today); actions.reschedule = nil }
                            Button("Tomorrow") { model.reschedule(item, to: today.plusDays(1)); actions.reschedule = nil }
                            Button("Next week") { model.reschedule(item, to: today.plusDays(7)); actions.reschedule = nil }
                            if !item.task.isRecurring && item.date != nil {
                                Button("Remove date", role: .destructive) { model.reschedule(item, to: nil); actions.reschedule = nil }
                            }
                        }
                        Section("Pick a date") {
                            DatePicker("Date", selection: $pickDate, displayedComponents: .date).datePickerStyle(.graphical)
                            Button("Move to \(Fmt.date(LocalDate(pickDate), today: today))") {
                                model.reschedule(item, to: LocalDate(pickDate)); actions.reschedule = nil
                            }
                        }
                    }
                    .navigationTitle("Reschedule")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { actions.reschedule = nil } } }
                }
                .onAppear { pickDate = (item.date ?? model.today).asDate }
            }
            .sheet(item: $actions.calendarExport) { item in
                EventEditView(item: item) { actions.calendarExport = nil }.ignoresSafeArea()
            }
    }
}

extension View {
    func rowActionSheets(_ actions: RowActionState) -> some View { modifier(RowActionSheets(actions: actions)) }
}

/// "Add to device calendar" using the system event editor. On iOS 17+ this needs no calendar permission.
struct EventEditView: UIViewControllerRepresentable {
    let item: TaskOccurrence
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = item.task.title
        event.notes = item.task.notes
        let day = (item.date ?? .today()).asDate
        if let t = item.time {
            event.startDate = Calendar.current.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: day)
            event.endDate = event.startDate.addingTimeInterval(TimeInterval((item.task.estimatedMinutes ?? 30) * 60))
        } else {
            event.isAllDay = true
            event.startDate = day
            event.endDate = day
        }
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = event
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { onDone() }
    }
}
