import PlannerCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ads: AdsManager
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notifStatus = UNAuthorizationStatus.notDetermined
    @State private var busy = false
    @State private var confirmRestore = false
    @State private var exporting = false
    @State private var importing = false
    @State private var starterSheet = false
    @State private var aiURL = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) { ForEach(ThemeMode.allCases) { Text($0.rawValue).tag($0) } }
                HStack {
                    Text("Accent")
                    Spacer()
                    ForEach(accentChoices.indices, id: \.self) { i in
                        Circle().fill(accentChoices[i].color).frame(width: 28, height: 28)
                            .overlay { if settings.accentIndex == i { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                            .frame(width: 36, height: 44)
                            .onTapGesture { settings.accentIndex = i }
                            .accessibilityLabel("\(accentChoices[i].name) accent")
                            .accessibilityAddTraits(settings.accentIndex == i ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }

            Section("Tasks") {
                Toggle("Open in Focus view (3 priority tasks)", isOn: $settings.focusDefault)
                Button("Add starter lists…") { starterSheet = true }
            }

            Section {
                Toggle("Reminders", isOn: Binding(get: { settings.remindersEnabled }, set: { v in
                    settings.remindersEnabled = v
                    Task {
                        if v { await NotificationScheduler.requestAuthorizationIfNeeded() }
                        await refreshStatus()
                        model.rescheduleReminders()
                    }
                }))
                Toggle("Fire reminders on this device", isOn: Binding(get: { settings.remindersOnThisDevice }, set: { v in
                    settings.remindersOnThisDevice = v; model.rescheduleReminders()
                }))
                if notifStatus == .denied {
                    Text("Notifications are blocked for this app, so reminders can't appear.").foregroundStyle(.red)
                    Button("Open iPhone Settings") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
                }
                Picker("Sound", selection: Binding(get: { settings.sound }, set: { settings.sound = $0; model.rescheduleReminders() })) {
                    ForEach(ReminderSound.allCases) { Text($0.rawValue).tag($0) }
                }
                DatePicker("All-day reminder time", selection: Binding(get: { settings.allDayTime.asDate }, set: {
                    settings.allDayMinutes = LocalTime($0).minutes; model.rescheduleReminders()
                }), displayedComponents: .hourAndMinute)
                Picker("Snooze length", selection: Binding(get: { settings.snoozeMinutes }, set: {
                    settings.snoozeMinutes = $0; NotificationScheduler.registerCategories(snoozeMinutes: $0)
                })) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
            } header: { Text("Reminders") } footer: {
                Text("Timing: iOS delivers reminders at the scheduled time. Focus modes and Notification Summary can delay or silence them. iOS keeps up to 64 scheduled reminders per app; the app tops them up automatically.")
            }

            Section {
                if !settings.driveSignedIn {
                    Text("Optional. Back up and sync your tasks to a private app folder in your Google Drive. The app can't see your other Drive files. Works with the Android app too.")
                        .font(.footnote)
                    Button("Sign in with Google") { signIn() }.disabled(busy)
                    if !DriveAuth.isConfigured { Text("Not available in this build yet: a Google iOS client ID is needed (see README).").font(.footnote).foregroundStyle(.secondary) }
                } else {
                    Text("Signed in" + (settings.driveAccount.map { " as \($0)" } ?? ""))
                    Text((settings.lastSyncAt.map { "Last sync: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not synced yet")
                         + (settings.lastSyncStatus.map { "\n" + $0 } ?? "")).font(.footnote).foregroundStyle(.secondary)
                    Toggle("Sync automatically", isOn: $settings.autoSync)
                    HStack {
                        Button("Back up now") { run(.backup) }.buttonStyle(.borderedProminent).disabled(busy)
                        Button("Restore") { confirmRestore = true }.buttonStyle(.bordered).disabled(busy)
                        if busy { ProgressView() }
                    }
                    Button("Sign out", role: .destructive) {
                        Task {
                            await DriveAuth.signOut()
                            settings.driveSignedIn = false; settings.driveAccount = nil
                            model.show("Signed out. Your tasks stay on this device.")
                        }
                    }
                }
            } header: { Text("Google Drive sync") }

            Section {
                Button("Export backup file") { exporting = true }
                Button("Import backup file") { importing = true }
            } header: { Text("Backup file") } footer: { Text("Saved with the Files app picker. No storage permission needed.") }

            Section {
                Toggle("Enable AI planner", isOn: $settings.aiEnabled)
                TextField("Backend URL (https://…)", text: $aiURL)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { settings.aiBackendURL = aiURL.trimmingCharacters(in: .whitespaces) }
                if aiURL != settings.aiBackendURL { Button("Save URL") { settings.aiBackendURL = aiURL.trimmingCharacters(in: .whitespaces) } }
            } header: { Text("AI planner") } footer: {
                Text("Uses your backend; you approve exactly what is sent each time. The offline planner always works.")
            }

            Section {
                Text("This app is free and shows ads from Google AdMob. Your tasks are never sent to advertisers.").font(.footnote)
                if ads.privacyOptionsRequired { Button("Ad privacy options") { ads.showPrivacyOptions() } }
            } header: { Text("Ads and privacy") }

            Section {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { aiURL = settings.aiBackendURL; await refreshStatus() }
        .onChange(of: scenePhase) { _, p in if p == .active { Task { await refreshStatus() } } }
        .confirmationDialog("Restore from Google Drive?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore") { run(.restore) }
        } message: {
            Text("Tasks from your Drive copy are merged into this device. Nothing on this device is lost, but tasks deleted elsewhere will be removed here. Reminders are rebuilt afterwards.")
        }
        .fileExporter(isPresented: $exporting, document: model.sync.exportDocument(), contentType: .json,
                      defaultFilename: "things-to-do-next-backup-\(LocalDate.today().isoString)") { result in
            if case .success = result { model.show("Backup exported") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            if case .success(let url) = result { model.show(model.sync.importBackup(url)) }
        }
        .sheet(isPresented: $starterSheet) { StarterPicker().presentationDetents([.medium]) }
    }

    private func refreshStatus() async { notifStatus = await NotificationScheduler.authorizationStatus() }

    private func signIn() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let r = try await DriveAuth.signIn()
                settings.driveSignedIn = true
                settings.driveAccount = r.email
                busy = false
                run(.sync, token: r.token)
            } catch {
                model.show((error as? LocalizedError)?.errorDescription ?? "Google sign-in was cancelled. Nothing changed.")
            }
        }
    }

    private func run(_ mode: SyncManager.Mode, token: String? = nil) {
        busy = true
        Task {
            let r = await model.sync.run(mode, token: token)
            busy = false
            switch r {
            case .success(let m): model.show(m)
            case .failure(let e): model.show((e as? LocalizedError)?.errorDescription ?? "Sync failed. Your tasks on this device are safe.")
            }
        }
    }
}

private struct StarterPicker: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Set<String>()
    var body: some View {
        NavigationStack {
            List(starterLists, id: \.key) { s in
                Button {
                    if picked.contains(s.key) { picked.remove(s.key) } else { picked.insert(s.key) }
                } label: {
                    HStack {
                        Image(systemName: picked.contains(s.key) ? "checkmark.circle.fill" : "circle")
                        ListDot(color: s.color)
                        Text(s.name).foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Starter lists")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { model.addStarterLists(picked); dismiss() }.disabled(picked.isEmpty) }
            }
        }
    }
}
