import Foundation
import PlannerCore

enum AppGroup {
    static let id = "group.com.robertlangat.thingstodonext"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

/// The local source of truth: one JSON file in the App Group container, shared by the app and the
/// widget. Every mutation is read-modify-write under a file coordinator, so the widget and the app
/// never overwrite each other's changes. Works fully offline.
final class SharedStore: @unchecked Sendable {
    static let shared = SharedStore()

    let fileURL: URL
    let deviceId: String
    let clock: HybridLogicalClock
    private let lock = NSLock()

    private init() {
        let fm = FileManager.default
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(ScreenshotMode.isOn ? "database-screenshots.json" : "database.json")
        let defaults = AppGroup.defaults
        if let id = defaults.string(forKey: "deviceId") {
            deviceId = id
        } else {
            let id = "ios-" + UUID().uuidString
            defaults.set(id, forKey: "deviceId")
            deviceId = id
        }
        clock = HybridLogicalClock()
        if ScreenshotMode.isOn { save(ScreenshotMode.demoDatabase()) }
        clock.observe(TaskOperations.maxVersion(load()))
    }

    var ops: TaskOperations { TaskOperations(clock: clock, deviceId: deviceId) }

    func load() -> Database {
        var result = Database()
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: &err) { url in
            if let data = try? Data(contentsOf: url), let db = try? JSONDecoder().decode(Database.self, from: data) {
                result = db
            }
        }
        return result
    }

    private func save(_ db: Database) {
        guard let data = try? JSONEncoder().encode(db) else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &err) { url in
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Read-modify-write. Returns whatever the body returns.
    @discardableResult
    func mutate<T>(_ body: (inout Database, TaskOperations) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        var db = load()
        clock.observe(TaskOperations.maxVersion(db))
        let result = body(&db, ops)
        save(db)
        return result
    }

    func replace(_ db: Database) {
        lock.lock(); defer { lock.unlock() }
        save(db)
    }
}
