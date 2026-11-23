import Foundation
import PlannerCore
import SwiftUI

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "Follow system", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

enum ReminderSound: String, CaseIterable, Identifiable {
    case standard = "Default sound", silent = "Silent"
    var id: String { rawValue }
}

let accentChoices: [(name: String, color: Color)] = [
    ("Blue", Color(red: 0.18, green: 0.36, blue: 1.0)), ("Teal", Color(red: 0.0, green: 0.41, blue: 0.43)),
    ("Purple", Color(red: 0.43, green: 0.25, blue: 0.82)), ("Green", Color(red: 0.18, green: 0.42, blue: 0.12)),
    ("Orange", Color(red: 0.8, green: 0.36, blue: 0.0)), ("Pink", Color(red: 0.69, green: 0.14, blue: 0.42)),
]

/// User preferences, stored in the App Group so the widget sees them too.
@MainActor
final class AppSettings: ObservableObject {
    private let d = AppGroup.defaults

    @Published var theme: ThemeMode { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var accentIndex: Int { didSet { d.set(accentIndex, forKey: "accent") } }
    @Published var focusDefault: Bool { didSet { d.set(focusDefault, forKey: "focusDefault") } }
    @Published var remindersEnabled: Bool { didSet { d.set(remindersEnabled, forKey: "remindersEnabled") } }
    /// Per device; not synced.
    @Published var remindersOnThisDevice: Bool { didSet { d.set(remindersOnThisDevice, forKey: "remindersHere") } }
    @Published var sound: ReminderSound { didSet { d.set(sound.rawValue, forKey: "sound") } }
    @Published var allDayMinutes: Int { didSet { d.set(allDayMinutes, forKey: "allDayMinutes") } }
    @Published var snoozeMinutes: Int { didSet { d.set(snoozeMinutes, forKey: "snoozeMinutes") } }
    @Published var aiEnabled: Bool { didSet { d.set(aiEnabled, forKey: "aiEnabled") } }
    @Published var aiBackendURL: String { didSet { d.set(aiBackendURL, forKey: "aiURL") } }
    @Published var driveSignedIn: Bool { didSet { d.set(driveSignedIn, forKey: "driveSignedIn") } }
    @Published var driveAccount: String? { didSet { d.set(driveAccount, forKey: "driveAccount") } }
    @Published var autoSync: Bool { didSet { d.set(autoSync, forKey: "autoSync") } }
    @Published var lastSyncAt: Date? { didSet { d.set(lastSyncAt?.timeIntervalSince1970, forKey: "lastSyncAt") } }
    @Published var lastSyncStatus: String? { didSet { d.set(lastSyncStatus, forKey: "lastSyncStatus") } }
    @Published var starterOffered: Bool { didSet { d.set(starterOffered, forKey: "starterOffered") } }

    init() {
        theme = ThemeMode(rawValue: d.string(forKey: "theme") ?? "") ?? .system
        accentIndex = d.integer(forKey: "accent")
        focusDefault = d.bool(forKey: "focusDefault")
        remindersEnabled = d.object(forKey: "remindersEnabled") as? Bool ?? true
        remindersOnThisDevice = d.object(forKey: "remindersHere") as? Bool ?? true
        sound = ReminderSound(rawValue: d.string(forKey: "sound") ?? "") ?? .standard
        allDayMinutes = d.object(forKey: "allDayMinutes") as? Int ?? 9 * 60
        snoozeMinutes = d.object(forKey: "snoozeMinutes") as? Int ?? 10
        aiEnabled = d.bool(forKey: "aiEnabled")
        aiBackendURL = d.string(forKey: "aiURL") ?? (Bundle.main.object(forInfoDictionaryKey: "AIBackendURL") as? String ?? "")
        driveSignedIn = d.bool(forKey: "driveSignedIn")
        driveAccount = d.string(forKey: "driveAccount")
        autoSync = d.object(forKey: "autoSync") as? Bool ?? true
        lastSyncAt = (d.object(forKey: "lastSyncAt") as? Double).map(Date.init(timeIntervalSince1970:))
        lastSyncStatus = d.string(forKey: "lastSyncStatus")
        starterOffered = d.bool(forKey: "starterOffered")
        if ScreenshotMode.isOn {
            starterOffered = true; theme = .system; accentIndex = 0; focusDefault = false; remindersEnabled = true
        }
    }

    /// The AI planner is offered only when a backend URL was configured for this build or entered by the user.
    var aiAvailable: Bool { !aiBackendURL.trimmingCharacters(in: .whitespaces).isEmpty || Self.buildAIURL != nil }
    static var buildAIURL: String? {
        let s = (Bundle.main.object(forInfoDictionaryKey: "AIBackendURL") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    var allDayTime: LocalTime { LocalTime(minutes: allDayMinutes) }
    var accent: Color { accentChoices[max(0, min(accentChoices.count - 1, accentIndex))].color }
}
