import BackgroundTasks
import GoogleSignIn
import PlannerCore
import SwiftUI
import UserNotifications

@main
struct ThingsToDoNextApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings: AppSettings
    @StateObject private var model: AppModel
    @StateObject private var ads = AdsManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        let m = AppModel(settings: s)
        _model = StateObject(wrappedValue: m)
        AppDelegate.model = m
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(settings)
                .environmentObject(ads)
                .tint(settings.accent)
                .preferredColorScheme(settings.theme.scheme)
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) { return }
                    handleDeepLink(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    // Midnight, clock or time-zone change: rebuild reminders and refresh "today".
                    model.reload(); model.afterChange(fromSync: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    model.reload(); model.afterChange(fromSync: true)
                }
                .task { ads.gatherConsent() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reload() // picks up completions made from the widget
                NotificationScheduler.registerCategories(snoozeMinutes: settings.snoozeMinutes)
                model.rescheduleReminders()
                model.watch.publish()
            }
            if phase == .background { AppDelegate.scheduleRefresh() }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "thingstodonext" else { return }
        switch url.host {
        case "quickadd": model.quickAddRequested = true
        case "task":
            let parts = url.pathComponents.filter { $0 != "/" }
            if let id = parts.first { model.openTaskRequest = (id, parts.dropFirst().first.flatMap { LocalDate(iso: $0) }) }
        default: break
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let refreshTaskId = "com.robertlangat.thingstodonext.refresh"
    @MainActor static weak var model: AppModel?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            Self.handleRefresh(task as! BGAppRefreshTask)
        }
        return true
    }

    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Background top-up of the 64-notification window, plus automatic sync.
    static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleRefresh()
        let work = Task { @MainActor in
            guard let model else { return }
            model.reload()
            let s = model.settings
            await NotificationScheduler.reconcile(db: model.db, enabled: s.remindersEnabled && s.remindersOnThisDevice,
                                                  allDayTime: s.allDayTime, silent: s.sound == .silent)
            if s.driveSignedIn && s.autoSync { _ = await model.sync.run(.sync) }
        }
        task.expirationHandler = { work.cancel() }
        Task { _ = await work.result; task.setTaskCompleted(success: true) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let taskId = info["taskId"] as? String, let date = (info["date"] as? String).flatMap({ LocalDate(iso: $0) }) else { return }
        await MainActor.run {
            guard let model = Self.model else { return }
            switch response.actionIdentifier {
            case NotificationScheduler.completeAction:
                model.perform { db, ops in ops.setCompleted(taskId, occurrence: date, completed: true, in: &db) }
            case NotificationScheduler.snoozeAction:
                model.snooze(taskId: taskId, date: date)
            default:
                model.openTaskRequest = (taskId, date)
            }
        }
    }
}
