import PlannerCore
import SwiftUI

struct TasksScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    let onOpen: (TaskOccurrence) -> Void
    let onAdd: () -> Void
    @Binding var currentList: String?

    @State private var view: TaskView = .today
    @State private var query = ""
    @State private var filters = Filters()
    @State private var showFilters = false
    @State private var focusMode: Bool?
    @State private var newList = false
    @State private var editList: TaskList?
    @State private var showPlanner = false
    @StateObject private var actions = RowActionState()

    private var isFocus: Bool { focusMode ?? settings.focusDefault }

    private var title: String {
        if isFocus { return "Focus" }
        if case .list(let id) = view { return model.data.listsById[id]?.name ?? "List" }
        return view.title
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !settings.starterOffered && model.data.lists.isEmpty { StarterListsCard() }
                if isFocus && query.isEmpty {
                    FocusView(items: TaskViews.focus(model.data, today: model.today), onOpen: onOpen, actions: actions)
                } else {
                    if query.isEmpty { chips }
                    list
                }
            }
            .navigationTitle(title)
            .searchable(text: $query, prompt: "Search tasks, notes, subtasks")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showFilters = true } label: {
                        Image(systemName: filters.active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel(filters.active ? "Filters (active)" : "Filters")
                    Button { showPlanner = true } label: { Image(systemName: "sparkles") }.accessibilityLabel("Plan my day")
                    Button { focusMode = !isFocus } label: { Image(systemName: isFocus ? "list.bullet" : "scope") }
                        .accessibilityLabel(isFocus ? "Show all tasks" : "Focus view")
                }
            }
            .overlay(alignment: .bottomTrailing) { AddButton(action: onAdd) }
            .sheet(isPresented: $showFilters) { FiltersSheet(filters: $filters).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $newList) {
                ListEditorSheet(list: nil) { name, color, icon in
                    let id = model.createList(name, color: color, icon: icon)
                    view = .list(id)
                }
            }
            .sheet(item: $editList) { l in
                ListEditorSheet(list: l, onSave: { name, color, icon in model.updateList(l.id, name: name, color: color, icon: icon) },
                                onDelete: { model.deleteList(l.id); view = .inbox })
            }
            .navigationDestination(isPresented: $showPlanner) { PlannerScreen() }
            .rowActionSheets(actions)
            .onChange(of: view) { _, v in if case .list(let id) = v { currentList = id } else { currentList = nil } }
            .onChange(of: model.data.lists.map(\.id)) { _, ids in
                if case .list(let id) = view, !ids.contains(id) { view = .today }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TaskView.builtIn, id: \.self) { v in
                    Chip(title: v.title, selected: view == v) { view = v }
                }
                ForEach(model.data.lists) { l in
                    let selected = view == .list(l.id)
                    Chip(title: l.name, selected: selected, color: l.color, trailingIcon: selected ? "pencil" : nil) {
                        if selected { editList = l } else { view = .list(l.id) }
                    }
                    .accessibilityHint(selected ? "Double-tap to edit this list" : "")
                }
                Button { newList = true } label: { Label("New List", systemImage: "plus") }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var list: some View {
        let sections = TaskViews.build(view, model.data, today: model.today, query: query, filters: filters,
                                       dateLabel: { Fmt.date($0, today: model.today) })
        return Group {
            if sections.allSatisfy({ $0.items.isEmpty }) {
                ContentUnavailableView(emptyText, systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(sections) { s in
                        if !s.items.isEmpty {
                            Section {
                                ForEach(s.items) { item in
                                    TaskRow(actions: actions, item: item,
                                            showDate: view != .today || !query.isEmpty || item.isOverdue(model.today), onOpen: onOpen)
                                }
                            } header: {
                                if let t = s.title { Text(t) }
                            }
                        }
                    }
                    Color.clear.frame(height: 72).listRowBackground(Color.clear)
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private var emptyText: String {
        if !query.isEmpty { return "No tasks match “\(query)”." }
        if filters.active { return "No tasks match these filters." }
        switch view {
        case .today: return "Nothing due today. Tap + to add a task."
        case .completed: return "Completed tasks will appear here."
        case .starred: return "Star important tasks to see them here."
        default: return "No tasks yet. Tap + to add one."
        }
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    var color: Int64?
    var trailingIcon: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if color != nil { ListDot(color: color) }
                Text(title)
                if let trailingIcon { Image(systemName: trailingIcon).font(.caption) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground)))
            .overlay(Capsule().stroke(selected ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StarterListsCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @State private var picked = Set(starterLists.map(\.key))

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Start with some lists?").font(.headline)
            Text("Pick any you'd like. You can add, rename or delete lists any time.").font(.footnote).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(starterLists, id: \.key) { s in
                        Chip(title: s.name, selected: picked.contains(s.key), color: s.color) {
                            if picked.contains(s.key) { picked.remove(s.key) } else { picked.insert(s.key) }
                        }
                    }
                }
            }
            HStack {
                Button("Add \(picked.count) lists") { model.addStarterLists(picked) }.buttonStyle(.borderedProminent).disabled(picked.isEmpty)
                Button("No thanks") { settings.starterOffered = true }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .padding()
    }
}

/// Three priority tasks, big checkboxes, one-tap rescheduling.
struct FocusView: View {
    @EnvironmentObject private var model: AppModel
    let items: [TaskOccurrence]
    let onOpen: (TaskOccurrence) -> Void
    @ObservedObject var actions: RowActionState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your top \(max(1, items.count)) for today").font(.title3.bold())
                if items.isEmpty {
                    Text("You're all caught up. Add a task or switch back to the full list.").foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Button { model.toggle(item) } label: {
                            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 40))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Complete \(item.task.title)")
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { PriorityBadge(priority: item.task.priority); Text(item.task.title).font(.title3.weight(.medium)) }
                            let meta = [item.date.map { Fmt.date($0, today: model.today) }, item.time.map(Fmt.time)].compactMap { $0 }.joined(separator: " · ")
                            if !meta.isEmpty { Text(meta).foregroundStyle(item.isOverdue(model.today) ? .red : .secondary) }
                            HStack {
                                Button("Tomorrow") { model.reschedule(item, to: model.today.plusDays(1)) }
                                Button("Reschedule…") { actions.reschedule = item }
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    .onTapGesture { onOpen(item) }
                }
                Spacer(minLength: 90)
            }
            .padding()
        }
    }
}

struct FiltersSheet: View {
    @Binding var filters: Filters
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Status", selection: $filters.status) { ForEach(StatusFilter.allCases, id: \.self) { Text($0.rawValue) } }
                Picker("Date", selection: $filters.date) { ForEach(DateFilter.allCases, id: \.self) { Text($0.rawValue) } }
                Section("Priority") {
                    ForEach([3, 2, 1, 0], id: \.self) { p in
                        Toggle(isOn: Binding(get: { filters.priorities.contains(p) },
                                             set: { if $0 { filters.priorities.insert(p) } else { filters.priorities.remove(p) } })) {
                            Text(p == 0 ? "None" : "\(Fmt.priorityLabel(p)) \(Fmt.priorityMarks(p))")
                        }
                    }
                }
                Picker("List", selection: Binding(get: { filters.listId ?? "*" }, set: { filters.listId = $0 == "*" ? nil : $0 })) {
                    Text("Any").tag("*")
                    Text("Inbox").tag("")
                    ForEach(model.data.lists) { Text($0.name).tag($0.id) }
                }
                Button("Clear filters") { filters = Filters() }.disabled(!filters.active)
            }
            .navigationTitle("Filters")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Step 2 of "New List": name (required), optional color and icon. Also used for editing.
struct ListEditorSheet: View {
    let list: TaskList?
    let onSave: (String, Int64?, String?) -> Void
    var onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: Int64?
    @State private var icon: String?
    @FocusState private var focused: Bool

    init(list: TaskList?, onSave: @escaping (String, Int64?, String?) -> Void, onDelete: (() -> Void)? = nil) {
        self.list = list; self.onSave = onSave; self.onDelete = onDelete
        _name = State(initialValue: list?.name ?? "")
        _color = State(initialValue: list?.color)
        _icon = State(initialValue: list?.icon)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("List name", text: $name).focused($focused).submitLabel(.done)
                Section("Color (optional)") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                        ForEach(Fmt.listColors, id: \.self) { c in
                            Circle().fill(Fmt.color(c)).frame(width: 34, height: 34)
                                .overlay { if color == c { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                .frame(width: 44, height: 44)
                                .onTapGesture { color = color == c ? nil : c }
                                .accessibilityLabel("Color option")
                                .accessibilityAddTraits(color == c ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                }
                Section("Icon (optional)") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5)) {
                        ForEach(Fmt.iconKeys, id: \.self) { k in
                            Image(systemName: Fmt.listIcon(k)).font(.title3)
                                .foregroundStyle(icon == k ? Color.accentColor : .secondary)
                                .frame(width: 44, height: 44)
                                .onTapGesture { icon = icon == k ? nil : k }
                                .accessibilityLabel("\(k) icon")
                                .accessibilityAddTraits(icon == k ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                }
                if let onDelete {
                    Button("Delete list", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .navigationTitle(list == nil ? "New list" : "Edit list")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(name, color, icon); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = list == nil }
        }
    }
}

/// Title-only quick capture. Dictation works through the keyboard's microphone key, so the app
/// needs no microphone permission.
struct QuickAddSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onMore: (String, LocalDate?, String?) -> Void
    @State private var title = ""
    @State private var date: LocalDate?
    @State private var listId: String?
    @State private var pickDate = false
    @FocusState private var focused: Bool

    init(initialDate: LocalDate?, initialList: String?, onMore: @escaping (String, LocalDate?, String?) -> Void) {
        self.onMore = onMore
        _date = State(initialValue: initialDate)
        _listId = State(initialValue: initialList)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("What do you need to do?", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button(action: add) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add task")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let today = model.today
                    Chip(title: "Today", selected: date == today) { date = date == today ? nil : today }
                    Chip(title: "Tomorrow", selected: date == today.plusDays(1)) { date = date == today.plusDays(1) ? nil : today.plusDays(1) }
                    Chip(title: date.flatMap { $0 != today && $0 != today.plusDays(1) ? Fmt.date($0, today: today) : nil } ?? "Date…",
                         selected: false) { pickDate.toggle() }
                    Menu {
                        Button("Inbox") { listId = nil }
                        ForEach(model.data.lists) { l in Button(l.name) { listId = l.id } }
                    } label: {
                        Label(listId.flatMap { model.data.listsById[$0]?.name } ?? "Inbox", systemImage: "tray")
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Capsule().fill(Color(.secondarySystemBackground)))
                    }
                    Chip(title: "More options", selected: false, trailingIcon: "slider.horizontal.3") { onMore(title, date, listId) }
                }
            }
            if pickDate {
                DatePicker("Date", selection: Binding(get: { (date ?? model.today).asDate }, set: { date = LocalDate($0) }), displayedComponents: .date)
            }
        }
        .padding()
        .onAppear { focused = true }
    }

    private func add() {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.quickAdd(title, date: date, listId: listId)
        title = ""
    }
}
