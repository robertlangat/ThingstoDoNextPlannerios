import PlannerCore
import SwiftUI

struct PlannerScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ads: AdsManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var p = PlannerModel()

    var body: some View {
        Form {
            if let draft = p.draft {
                draftView(draft)
            } else {
                inputView
            }
        }
        .navigationTitle("Plan my day")
        .alert("Send to AI planner?", isPresented: Binding(get: { p.pendingPayload != nil }, set: { if !$0 { p.pendingPayload = nil } })) {
            Button("Send") { Task { await p.sendAI(model) } }
            Button("Cancel", role: .cancel) { p.pendingPayload = nil }
        } message: {
            Text("Only this will be sent to \(settings.aiBackendURL):\n\n\(p.pendingPayload ?? "")")
        }
    }

    @ViewBuilder private var inputView: some View {
        Section {
            TextField("Goal, rough task list, or your availability", text: $p.input, axis: .vertical).lineLimit(4...10)
        } footer: {
            Text("Example: “I have two hours after work. Help me revise for an exam and plan tomorrow's errands.” Phrases like “two hours after work” fill in the times below. Use the keyboard's microphone to dictate.")
        }
        Section("Available time") {
            DatePicker("Day", selection: Binding(get: { p.date.asDate }, set: { p.date = LocalDate($0) }), displayedComponents: .date)
            DatePicker("From", selection: Binding(get: { p.start.asDate }, set: { p.start = LocalTime($0) }), displayedComponents: .hourAndMinute)
            DatePicker("To", selection: Binding(get: { p.end.asDate }, set: { p.end = LocalTime($0) }), displayedComponents: .hourAndMinute)
            Toggle("Also plan my undated open tasks", isOn: $p.includeUndated)
        }
        Section {
            Picker("Planner", selection: $p.mode) { ForEach(PlannerMode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            if p.mode == .ai {
                if !settings.aiEnabled || settings.aiBackendURL.isEmpty {
                    Text("The AI planner is off. Turn it on and set a backend URL in Settings → AI planner. The offline planner always works.")
                        .font(.footnote)
                } else {
                    Toggle("Share titles of my scheduled tasks (otherwise sent as “Busy”)", isOn: $p.shareBusyTitles)
                    Text("You'll see exactly what will be sent before anything leaves your phone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let e = p.error { Text(e).foregroundStyle(.red) }
            HStack {
                Button("Create draft plan") { if p.mode == .offline { p.planOffline(model) } else { p.prepareAI(model) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(p.loading || (p.mode == .ai && (!settings.aiEnabled || settings.aiBackendURL.isEmpty)))
                if p.loading { ProgressView() }
                if p.error != nil && p.mode == .ai { Button("Use offline planner") { p.mode = .offline; p.planOffline(model) } }
            }
        }
    }

    @ViewBuilder private func draftView(_ draft: PlanDraft) -> some View {
        Section {
            Label {
                VStack(alignment: .leading) {
                    Text("Draft from the \(draft.source.rawValue)" + (draft.modelName.map { " (\($0))" } ?? "")).font(.headline)
                    Text(draft.summary).font(.footnote)
                }
            } icon: { Image(systemName: draft.source == .ai ? "sparkles" : "icloud.slash") }
            ForEach(draft.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
        } footer: { Text("Review each suggestion. Untick anything you don't want; change times and durations as you like.") }

        ForEach(draft.items) { item in
            Section {
                Toggle(isOn: Binding(get: { item.accepted }, set: { v in p.edit(item.id, model: model) { $0.accepted = v } })) {
                    TextField("Task", text: Binding(get: { item.task.title }, set: { v in p.edit(item.id, model: model) { $0.task.title = v } }))
                }
                DatePicker("Start", selection: Binding(
                    get: { item.slot.map { $0.start.date.asDate.addingTimeInterval(TimeInterval($0.start.time.minutes * 60)) } ?? p.start.asDate },
                    set: { d in
                        let s = LocalDateTime(LocalDate(d), LocalTime(d))
                        p.edit(item.id, model: model) { $0.slot = TimeWindow(s, s.plusMinutes($0.task.durationMinutes)) }
                    }), displayedComponents: [.date, .hourAndMinute])
                Stepper("\(item.task.durationMinutes) min", value: Binding(get: { item.task.durationMinutes }, set: { v in
                    p.edit(item.id, model: model) { it in
                        it.task.durationMinutes = v
                        if let s = it.slot { it.slot = TimeWindow(s.start, s.start.plusMinutes(v)) }
                    }
                }), in: 5...720, step: 5)
                if item.task.priority != .none { Text("\(String(describing: item.task.priority).capitalized) priority").font(.caption) }
                ForEach(item.task.subtasks, id: \.self) { Text("• " + $0).font(.footnote) }
                ForEach(Array(item.flags).sorted { $0.rawValue < $1.rawValue }, id: \.self) { f in
                    let extra = (f == .overlapsExisting || f == .overlapsDraft) && !item.conflictsWith.isEmpty ? ": " + item.conflictsWith.joined(separator: ", ") : ""
                    Label(f.text + extra, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                }
                if item.task.id.hasPrefix("existing:") { Text("Existing task - saving reschedules it").font(.caption2).foregroundStyle(.secondary) }
            }
        }

        Section {
            Button("Save \(draft.items.filter(\.accepted).count) to schedule") {
                let n = p.save(model)
                model.show("Saved \(n) task\(n == 1 ? "" : "s") to your schedule")
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ads.onNaturalBreak() }
            }
            .disabled(!draft.items.contains(where: \.accepted))
            Button("Back to input") { p.draft = nil }
        }
    }
}
