import PlannerCore
import SwiftUI

enum CalendarMode: String, CaseIterable, Identifiable { case day = "Day", week = "Week", month = "Month"; var id: String { rawValue } }

struct CalendarScreen: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selected: LocalDate
    let onOpen: (TaskOccurrence) -> Void
    let onAdd: () -> Void
    @State private var mode = CalendarMode.month
    @StateObject private var actions = RowActionState()

    private func weekStart(_ d: LocalDate) -> LocalDate { d.plusDays(-(d.weekday - 1)) }

    private var range: (LocalDate, LocalDate) {
        switch mode {
        case .day: return (selected, selected)
        case .week: return (weekStart(selected), weekStart(selected).plusDays(6))
        case .month:
            let first = LocalDate(selected.year, selected.month, 1)
            return (weekStart(first), weekStart(first).plusDays(41))
        }
    }

    private var title: String {
        let f = DateFormatter()
        switch mode {
        case .month: f.setLocalizedDateFormatFromTemplate("MMMMy")
        case .week: f.setLocalizedDateFormatFromTemplate("dMMM"); return "Week of " + f.string(from: weekStart(selected).asDate)
        case .day: f.dateStyle = .full
        }
        return f.string(from: selected.asDate)
    }

    var body: some View {
        let r = range
        let byDate = Dictionary(grouping: model.data.occurrences(from: r.0, to: r.1)) { $0.date! }
        let dayItems = AppData.sort(byDate[selected] ?? [])
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) { ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                switch mode {
                case .month: MonthGrid(selected: $selected, today: model.today, byDate: byDate)
                case .week: WeekStrip(selected: $selected, today: model.today, byDate: byDate)
                case .day: EmptyView()
                }
                Divider()
                if mode == .day {
                    DayTimeline(items: dayItems, actions: actions, onOpen: onOpen)
                } else {
                    List {
                        Section(Fmt.date(selected, today: model.today) + " · \(dayItems.count) task\(dayItems.count == 1 ? "" : "s")") {
                            if dayItems.isEmpty { Text("No tasks. Tap + to add one on this day.").foregroundStyle(.secondary) }
                            ForEach(dayItems) { TaskRow(actions: actions, item: $0, showDate: false, onOpen: onOpen) }
                        }
                        Color.clear.frame(height: 72).listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous \(mode.rawValue.lowercased())")
                    Button("Today") { selected = model.today }
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next \(mode.rawValue.lowercased())")
                }
            }
            .overlay(alignment: .bottomTrailing) { AddButton(action: onAdd) }
            .rowActionSheets(actions)
        }
    }

    private func step(_ n: Int) {
        switch mode {
        case .day: selected = selected.plusDays(n)
        case .week: selected = selected.plusDays(7 * n)
        case .month: selected = selected.plusMonths(n)
        }
    }
}

private let weekdayInitials = ["M", "T", "W", "T", "F", "S", "S"]

private struct DayCell: View {
    let date: LocalDate
    let items: [TaskOccurrence]
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("\(date.day)")
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(inMonth ? .primary : .tertiary)
                HStack(spacing: 2) {
                    ForEach(items.prefix(3)) { o in
                        Circle().fill(o.completed ? Color.gray : (o.list.map { Fmt.color($0.color) } ?? Color.accentColor)).frame(width: 5, height: 5)
                    }
                    if items.count > 3 { Text("+\(items.count - 3)").font(.system(size: 8)) }
                }
                .frame(height: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isToday ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Fmt.date(date) + (items.isEmpty ? ", no tasks" : ", \(items.count) tasks, \(items.filter { !$0.completed }.count) open"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MonthGrid: View {
    @Binding var selected: LocalDate
    let today: LocalDate
    let byDate: [LocalDate: [TaskOccurrence]]

    var body: some View {
        let first = LocalDate(selected.year, selected.month, 1)
        let start = first.plusDays(-(first.weekday - 1))
        VStack(spacing: 2) {
            HStack { ForEach(0..<7, id: \.self) { Text(weekdayInitials[$0]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { d in
                        let date = start.plusDays(w * 7 + d)
                        DayCell(date: date, items: byDate[date] ?? [], inMonth: date.month == selected.month,
                                isToday: date == today, isSelected: date == selected) { selected = date }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct WeekStrip: View {
    @Binding var selected: LocalDate
    let today: LocalDate
    let byDate: [LocalDate: [TaskOccurrence]]

    var body: some View {
        let start = selected.plusDays(-(selected.weekday - 1))
        VStack(spacing: 2) {
            HStack { ForEach(0..<7, id: \.self) { Text(weekdayInitials[$0]).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
            HStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { i in
                    let date = start.plusDays(i)
                    DayCell(date: date, items: byDate[date] ?? [], inMonth: true, isToday: date == today, isSelected: date == selected) { selected = date }
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct DayTimeline: View {
    let items: [TaskOccurrence]
    @ObservedObject var actions: RowActionState
    let onOpen: (TaskOccurrence) -> Void

    var body: some View {
        let allDay = items.filter { $0.time == nil }
        let byHour = Dictionary(grouping: items.filter { $0.time != nil }) { $0.time!.hour }
        let first = min(7, byHour.keys.min() ?? 7), last = max(21, byHour.keys.max() ?? 21)
        List {
            Section("All day") {
                if allDay.isEmpty { Text("No all-day tasks").foregroundStyle(.secondary) }
                ForEach(allDay) { TaskRow(actions: actions, item: $0, showDate: false, onOpen: onOpen) }
            }
            Section("Schedule") {
                ForEach(first...last, id: \.self) { h in
                    HStack(alignment: .top) {
                        Text(Fmt.time(LocalTime(h, 0))).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading).padding(.top, 12)
                        VStack(alignment: .leading) {
                            ForEach(byHour[h] ?? []) { TaskRow(actions: actions, item: $0, showDate: false, onOpen: onOpen) }
                        }
                    }
                    .frame(minHeight: 36)
                }
            }
            Color.clear.frame(height: 72).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
    }
}
