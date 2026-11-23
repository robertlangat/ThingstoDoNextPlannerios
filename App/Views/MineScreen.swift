import PlannerCore
import SwiftUI

struct MineScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let stats = ProgressCalculator.compute(model.data, today: model.today)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        StatCard(title: "Today", ratio: stats.today)
                        StatCard(title: "This week", ratio: stats.thisWeek)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    HStack {
                        Text("Overdue").font(.headline)
                        Spacer()
                        Text("\(stats.overdue)").font(.title.bold()).foregroundStyle(stats.overdue > 0 ? .red : .primary)
                    }
                    .accessibilityElement(children: .combine)
                } footer: { Text("Recurring tasks count each occurrence separately.") }

                Section("Progress by list") {
                    let rows: [(String, String, Int64?)] = [("", "Inbox", nil)] + model.data.lists.map { ($0.id, $0.name, $0.color) }
                    ForEach(rows, id: \.0) { id, name, color in
                        let r = stats.byList[id] ?? Ratio(0, 0)
                        if !(id.isEmpty && r.total == 0) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    ListDot(color: color)
                                    Text(name)
                                    Spacer()
                                    Text("\(r.done)/\(r.total)").monospacedDigit()
                                }
                                ProgressView(value: r.fraction)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(name): \(r.done) of \(r.total) done")
                        }
                    }
                }

                Section {
                    NavigationLink { PlannerScreen() } label: {
                        Label { VStack(alignment: .leading) { Text("Plan my day"); Text("Turn goals or a rough list into a schedule").font(.caption).foregroundStyle(.secondary) } }
                            icon: { Image(systemName: "sparkles") }
                    }
                    NavigationLink { SettingsScreen() } label: {
                        Label { VStack(alignment: .leading) { Text("Google Drive sync"); Text(syncText).font(.caption).foregroundStyle(.secondary) } }
                            icon: { Image(systemName: "arrow.triangle.2.circlepath.icloud") }
                    }
                    NavigationLink { SettingsScreen() } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .navigationTitle("Mine")
        }
    }

    private var syncText: String {
        guard settings.driveSignedIn else { return "Off · tasks are stored on this device" }
        if let at = settings.lastSyncAt { return "Last synced " + at.formatted(date: .abbreviated, time: .shortened) }
        return settings.lastSyncStatus ?? "Not synced yet"
    }
}

private struct StatCard: View {
    let title: String
    let ratio: Ratio
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text("\(ratio.done) / \(ratio.total)").font(.title.bold()).monospacedDigit()
            Text("completed").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: ratio.fraction)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(ratio.done) of \(ratio.total) completed")
    }
}
