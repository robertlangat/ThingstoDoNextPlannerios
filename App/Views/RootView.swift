import PlannerCore
import SwiftUI

enum AppTab: Hashable { case tasks, calendar, mine }

/// What the add sheet / editor should open with.
struct EditorRequest: Identifiable {
    let id = UUID()
    var taskId: String?
    var occurrence: LocalDate?
    var prefillTitle = ""
    var prefillDate: LocalDate?
    var prefillList: String?
}

struct QuickAddRequest: Identifiable {
    let id = UUID()
    var date: LocalDate?
    var listId: String?
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var ads: AdsManager
    @State private var tab = AppTab.tasks
    @State private var editor: EditorRequest?
    @State private var quickAdd: QuickAddRequest?
    @State private var calendarDate = LocalDate.today()
    @State private var currentList: String?

    var body: some View {
        TabView(selection: $tab) {
            TasksScreen(onOpen: open, onAdd: { quickAdd = QuickAddRequest(date: nil, listId: currentList) }, currentList: $currentList)
                .bottomBanner()
                .tabItem { Label("Tasks", systemImage: "checkmark.circle") }
                .tag(AppTab.tasks)
            CalendarScreen(selected: $calendarDate, onOpen: open, onAdd: { quickAdd = QuickAddRequest(date: calendarDate, listId: nil) })
                .bottomBanner()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(AppTab.calendar)
            MineScreen()
                .bottomBanner()
                .tabItem { Label("Mine", systemImage: "person") }
                .tag(AppTab.mine)
        }
        .sheet(item: $quickAdd) { req in
            QuickAddSheet(initialDate: req.date, initialList: req.listId) { title, date, list in
                quickAdd = nil
                editor = EditorRequest(prefillTitle: title, prefillDate: date, prefillList: list)
            }
            .presentationDetents([.height(230), .medium])
        }
        .sheet(item: $editor) { req in
            TaskEditorView(request: req, onSaved: {
                editor = nil
                // Natural break: may show a frequency-capped interstitial after the sheet closes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ads.onNaturalBreak() }
            })
        }
        .overlay(alignment: .bottom) { ToastView() }
        .onChange(of: model.quickAddRequested) { _, requested in
            if requested { tab = .tasks; quickAdd = QuickAddRequest(); model.quickAddRequested = false }
        }
        .onChange(of: model.openTaskRequest?.id) { _, id in
            if let req = model.openTaskRequest, id != nil {
                editor = EditorRequest(taskId: req.id, occurrence: req.date)
                model.openTaskRequest = nil
            }
        }
    }

    private func open(_ o: TaskOccurrence) { editor = EditorRequest(taskId: o.task.id, occurrence: o.date) }
}

extension View {
    /// Places the AdMob banner just above the tab bar.
    func bottomBanner() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { BannerAdView() }
    }
}

/// Floating add button, kept visible on Tasks and Calendar.
struct AddButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(radius: 4, y: 2)
        }
        .accessibilityLabel("Add task")
        .padding(20)
    }
}

struct ToastView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let toast = model.toast {
            HStack {
                Text(toast.text).lineLimit(2)
                Spacer()
                if let label = toast.actionLabel, let action = toast.action {
                    Button(label) { action(); model.toast = nil }.bold()
                }
            }
            .padding()
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .padding(.bottom, 120)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
