import PlannerCore
import SwiftUI

func offsetLabel(_ m: Int) -> String {
    if m == 0 { return "At time of task" }
    if m % 1440 == 0 { return "\(m / 1440) day\(m == 1440 ? "" : "s") before" }
    if m % 60 == 0 { return "\(m / 60) hour\(m == 60 ? "" : "s") before" }
    return "\(m) min before"
}

enum RepeatChoice: String, CaseIterable, Identifiable {
    case never = "Doesn't repeat", daily = "Daily", weekdays = "Every weekday", weekly = "Weekly", monthly = "Monthly",
         yearly = "Yearly (birthdays, anniversaries)", custom = "Custom…"
    var id: String { rawValue }
}

struct TaskEditorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest
    let onSaved: () -> Void

    @State private var draft = TaskDraft(title: "")
    @State private var original: TaskDraft?
    @State private var completed = false
    @State private var loaded = false
    @State private var askScope = false
    @State private var customRepeat = false
    @State private var customReminder = false
    @State private var error: String?
    @State private var notificationsDenied = false
    @FocusState private var titleFocused: Bool

    private var isNew: Bool { request.taskId == nil }
    private var isRecurring: Bool { original?.rule != nil }
    private var changed: Bool { original.map { !draft.sameContent(as: $0) } ?? true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title, axis: .vertical).focused($titleFocused).font(.title3)
                    if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    if !isNew {
                        Button(completed ? "Reopen" + (isRecurring ? " (this occurrence)" : "") : "Mark complete" + (isRecurring ? " (this occurrence)" : "")) {
                            toggleComplete()
                        }
                    }
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical).lineLimit(2...6)
                }

                Section {
                    Picker("List", selection: $draft.listId) {
                        Text("Inbox").tag(String?.none)
                        ForEach(model.data.lists) { l in Text(l.name).tag(Optional(l.id)) }
                    }
                    Picker("Priority", selection: $draft.priority) {
                        Text("None").tag(0)
                        ForEach([1, 2, 3], id: \.self) { p in Text("\(Fmt.priorityMarks(p)) \(Fmt.priorityLabel(p))").tag(p) }
                    }
                    Toggle("Starred", isOn: $draft.starred)
                }

                Section("When") {
                    Toggle("Date", isOn: Binding(get: { draft.dueDate != nil }, set: { on in
                        if on { draft.dueDate = draft.dueDate ?? model.today } else { draft.dueDate = nil; draft.dueTime = nil; draft.rule = nil; draft.reminderOffsets = [] }
                    }))
                    if let due = draft.dueDate {
                        DatePicker("Due", selection: Binding(get: { due.asDate }, set: { draft.dueDate = LocalDate($0) }), displayedComponents: .date)
                        Toggle("Time (off = all day)", isOn: Binding(get: { draft.dueTime != nil }, set: { draft.dueTime = $0 ? (draft.dueTime ?? LocalTime(9, 0)) : nil }))
                        if let t = draft.dueTime {
                            DatePicker("Time", selection: Binding(get: { t.asDate }, set: { draft.dueTime = LocalTime($0) }), displayedComponents: .hourAndMinute)
                        }
                        Picker("Repeat", selection: Binding(get: { repeatChoice }, set: setRepeat)) {
                            ForEach(RepeatChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        if let r = draft.rule { Text(r.describe(start: due)).font(.footnote).foregroundStyle(.secondary) }
                        if draft.rule?.frequency == .MONTHLY && due.day > 28 {
                            Text("In shorter months this falls on the last day of the month.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                if draft.dueDate != nil {
                    Section {
                        ForEach(draft.reminderOffsets, id: \.self) { m in
                            Text(offsetLabel(m))
                        }
                        .onDelete { idx in draft.reminderOffsets.remove(atOffsets: idx) }
                        Menu {
                            ForEach([0, 5, 15, 30, 60, 120, 1440, 2880, 10080], id: \.self) { m in
                                Button(offsetLabel(m)) { addReminder(m) }
                            }
                            Button("Custom…") { customReminder = true }
                        } label: { Label("Add reminder", systemImage: "bell.badge") }
                    } header: { Text("Reminders") } footer: {
                        VStack(alignment: .leading) {
                            if draft.dueTime == nil && !draft.reminderOffsets.isEmpty {
                                Text("All-day task: reminders use your all-day reminder time (\(Fmt.time(settings.allDayTime))).")
                            }
                            if notificationsDenied { Text("Notifications are off for this app, so reminders won't appear. Your task is still saved.") }
                            if !settings.remindersEnabled { Text("Reminders are turned off in Settings.") }
                        }
                    }
                }

                Section("Details") {
                    TextField("Estimated duration (minutes, optional)", value: $draft.estimatedMinutes, format: .number).keyboardType(.numberPad)
                }

                Section("Subtasks") {
                    ForEach($draft.subtasks) { $s in
                        HStack {
                            Button { s.done.toggle() } label: { Image(systemName: s.done ? "checkmark.circle.fill" : "circle") }
                                .buttonStyle(.plain)
                                .accessibilityLabel(s.done ? "Subtask done" : "Subtask not done")
                            TextField("Subtask", text: $s.title)
                        }
                    }
                    .onDelete { draft.subtasks.remove(atOffsets: $0) }
                    .onMove { draft.subtasks.move(fromOffsets: $0, toOffset: $1) }
                    Button { draft.subtasks.append(SubtaskDraft(title: "")) } label: { Label("Add subtask", systemImage: "plus") }
                }
            }
            .navigationTitle(isNew ? "New task" : "Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if !isNew && isRecurring && request.occurrence != nil && changed { askScope = true } else { save(.all) }
                    }
                    .bold()
                }
            }
            .confirmationDialog("Save changes to repeating task", isPresented: $askScope, titleVisibility: .visible) {
                Button("This occurrence") { save(.thisOccurrence) }
                Button("This and future occurrences") { save(.thisAndFuture) }
                Button("All occurrences") { save(.all) }
            }
            .sheet(isPresented: $customRepeat) {
                CustomRepeatSheet(initial: draft.rule, start: draft.dueDate ?? model.today) { draft.rule = $0 }
            }
            .sheet(isPresented: $customReminder) {
                CustomReminderSheet { addReminder($0) }.presentationDetents([.height(260)])
            }
            .onAppear(perform: load)
        }
    }

    private var repeatChoice: RepeatChoice {
        guard let r = draft.rule else { return .never }
        let simple = r.interval == 1 && r.end == .never && r.byDays.isEmpty
        switch r.frequency {
        case .DAILY: return simple ? .daily : .custom
        case .WEEKDAYS: return .weekdays
        case .WEEKLY: return simple ? .weekly : .custom
        case .MONTHLY: return simple ? .monthly : .custom
        case .YEARLY: return simple ? .yearly : .custom
        }
    }

    private func setRepeat(_ c: RepeatChoice) {
        let ex = draft.rule?.exDates ?? []
        switch c {
        case .never: draft.rule = nil
        case .daily: draft.rule = RecurrenceRule(.DAILY, exDates: ex)
        case .weekdays: draft.rule = RecurrenceRule(.WEEKDAYS, exDates: ex)
        case .weekly: draft.rule = RecurrenceRule(.WEEKLY, exDates: ex)
        case .monthly: draft.rule = RecurrenceRule(.MONTHLY, exDates: ex)
        case .yearly: draft.rule = RecurrenceRule(.YEARLY, exDates: ex)
        case .custom: customRepeat = true
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let id = request.taskId, let d = model.store.ops.draft(of: id, in: model.db) {
            draft = d
            original = d
            let t = model.db.tasks.first { $0.id == id }
            completed = (t?.isRecurring == true && request.occurrence != nil)
                ? model.data.completedDates(id).contains(request.occurrence!) : (t?.completed ?? false)
        } else if request.taskId != nil {
            model.show("This task no longer exists.")
            dismiss()
        } else {
            draft = TaskDraft(title: request.prefillTitle, listId: request.prefillList, dueDate: request.prefillDate)
            titleFocused = true
        }
    }

    private func addReminder(_ m: Int) {
        if !draft.reminderOffsets.contains(m) { draft.reminderOffsets.append(m); draft.reminderOffsets.sort() }
        Task {
            let ok = await NotificationScheduler.requestAuthorizationIfNeeded()
            notificationsDenied = !ok
        }
    }

    private func toggleComplete() {
        guard let id = request.taskId else { return }
        let target = !completed
        let occ = request.occurrence ?? original?.dueDate
        model.perform { db, ops in ops.setCompleted(id, occurrence: occ, completed: target, in: &db) }
        completed = target
    }

    private func save(_ scope: EditScope) {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "Give the task a title"; return }
        let d = draft
        if let id = request.taskId {
            model.perform { db, ops in ops.update(id, d, scope: scope, occurrence: request.occurrence, in: &db) }
        } else {
            model.perform { db, ops in ops.create(d, in: &db) }
        }
        onSaved()
    }
}

private struct CustomReminderSheet: View {
    let onAdd: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amount = 10
    @State private var unit = 1
    var body: some View {
        NavigationStack {
            Form {
                Stepper("\(amount)", value: $amount, in: 1...999)
                Picker("Before the task", selection: $unit) {
                    Text("Minutes").tag(1); Text("Hours").tag(60); Text("Days").tag(1440)
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle("Custom reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { onAdd(min(amount * unit, 60 * 24 * 60)); dismiss() } }
            }
        }
    }
}

struct CustomRepeatSheet: View {
    let initial: RecurrenceRule?
    let start: LocalDate
    let onSave: (RecurrenceRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var interval = 1
    @State private var freq = Frequency.WEEKLY
    @State private var days: Set<Int> = []
    @State private var endKind = 0
    @State private var until = Date()
    @State private var count = 10

    var body: some View {
        NavigationStack {
            Form {
                Stepper("Every \(interval) \(unitName)", value: $interval, in: 1...365)
                Picker("Unit", selection: $freq) {
                    Text("Days").tag(Frequency.DAILY); Text("Weeks").tag(Frequency.WEEKLY)
                    Text("Months").tag(Frequency.MONTHLY); Text("Years").tag(Frequency.YEARLY)
                }
                .pickerStyle(.segmented)
                if freq == .WEEKLY {
                    Section("On") {
                        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
                        ForEach(1...7, id: \.self) { d in
                            Toggle(names[d - 1], isOn: Binding(get: { days.contains(d) }, set: { on in
                                if on { days.insert(d) } else if days.count > 1 { days.remove(d) }
                            }))
                        }
                    }
                }
                Section("Ends") {
                    Picker("Ends", selection: $endKind) {
                        Text("Never").tag(0); Text("On date").tag(1); Text("After a number of times").tag(2)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if endKind == 1 { DatePicker("End date", selection: $until, in: start.asDate..., displayedComponents: .date) }
                    if endKind == 2 { Stepper("\(count) times", value: $count, in: 1...999) }
                }
            }
            .navigationTitle("Custom repeat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let end: RecurrenceEnd = endKind == 1 ? .until(LocalDate(until)) : endKind == 2 ? .count(count) : .never
                        onSave(RecurrenceRule(freq, interval: interval, byDays: freq == .WEEKLY ? days : [], end: end, exDates: initial?.exDates ?? []))
                        dismiss()
                    }
                }
            }
            .onAppear {
                interval = initial?.interval ?? 1
                freq = initial.map { $0.frequency == .WEEKDAYS ? .WEEKLY : $0.frequency } ?? .WEEKLY
                days = initial?.byDays.isEmpty == false ? initial!.byDays : [start.weekday]
                switch initial?.end {
                case .until(let d)?: endKind = 1; until = d.asDate
                case .count(let n)?: endKind = 2; count = n
                default: endKind = 0; until = start.plusMonths(3).asDate
                }
            }
        }
    }

    private var unitName: String {
        switch freq {
        case .DAILY, .WEEKDAYS: return interval == 1 ? "day" : "days"
        case .WEEKLY: return interval == 1 ? "week" : "weeks"
        case .MONTHLY: return interval == 1 ? "month" : "months"
        case .YEARLY: return interval == 1 ? "year" : "years"
        }
    }
}
