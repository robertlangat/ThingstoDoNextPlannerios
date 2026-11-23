import Foundation
import GoogleSignIn
import PlannerCore
import SwiftUI
import UniformTypeIdentifiers

/// Google sign-in with the Drive app-data scope only (the app's hidden folder; nothing else in Drive).
enum DriveAuth {
    static let scope = "https://www.googleapis.com/auth/drive.appdata"

    /// True when this build has a real OAuth client ID (see README "Google Drive sync").
    static var isConfigured: Bool {
        let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        return id.hasSuffix(".apps.googleusercontent.com") && !id.contains("PLACEHOLDER")
    }

    @MainActor
    static func signIn() async throws -> (token: String, email: String?) {
        guard isConfigured else { throw SyncError.notConfigured }
        guard let vc = AdsManager.rootViewController else { throw SyncError.message("Couldn't show the Google sign-in screen.") }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: vc, hint: nil, additionalScopes: [scope])
        var user = result.user
        if !(user.grantedScopes ?? []).contains(scope) {
            user = try await user.addScopes([scope], presenting: vc).user
        }
        return (user.accessToken.tokenString, user.profile?.email)
    }

    /// Token for background work, or nil if the user must sign in again.
    @MainActor
    static func silentToken() async -> String? {
        guard isConfigured else { return nil }
        let user: GIDGoogleUser
        if let current = GIDSignIn.sharedInstance.currentUser {
            user = current
        } else if let restored = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() {
            user = restored
        } else { return nil }
        guard (user.grantedScopes ?? []).contains(scope), let fresh = try? await user.refreshTokensIfNeeded() else { return nil }
        return fresh.accessToken.tokenString
    }

    @MainActor
    static func signOut() async {
        if GIDSignIn.sharedInstance.currentUser != nil { try? await GIDSignIn.sharedInstance.disconnect() }
        GIDSignIn.sharedInstance.signOut()
    }
}

enum SyncError: Error, LocalizedError {
    case notConfigured, needsSignIn, http(Int), message(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google sign-in isn't set up in this build yet (needs a Google iOS client ID)."
        case .needsSignIn: return "Google access expired - sign in again."
        case .http(let c): return "Google Drive error (\(c)). Your tasks on this device are safe."
        case .message(let m): return m
        }
    }
}

/// Minimal Drive v3 REST client for the hidden appDataFolder.
struct DriveClient {
    static let syncFile = "todoplanner-sync-v1.json" // same file the Android app uses
    let token: String

    struct File { let id: String; let headRevisionId: String? }

    private func request(_ method: String, _ url: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw SyncError.needsSignIn }
        guard (200..<300).contains(code) else { throw SyncError.http(code) }
        return data
    }

    func findSyncFiles() async throws -> [File] {
        let q = "name = '\(Self.syncFile)' and trashed = false".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let data = try await request("GET", "https://www.googleapis.com/drive/v3/files?spaces=appDataFolder&q=\(q)&orderBy=createdTime&fields=files(id,headRevisionId)")
        return (try JSONValue.parse(data).object?["files"]?.array ?? []).compactMap { v in
            v.object?["id"]?.string.map { File(id: $0, headRevisionId: v.object?["headRevisionId"]?.string) }
        }
    }

    func download(_ id: String) async throws -> Data { try await request("GET", "https://www.googleapis.com/drive/v3/files/\(id)?alt=media") }

    func create(_ content: Data) async throws {
        let boundary = "ttdn-" + UUID().uuidString
        let meta = #"{"name":"\#(Self.syncFile)","parents":["appDataFolder"],"mimeType":"application/json"}"#
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n\(meta)\r\n--\(boundary)\r\nContent-Type: application/json\r\n\r\n".utf8)
        body.append(content)
        body.append(Data("\r\n--\(boundary)--".utf8))
        _ = try await request("POST", "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id", body: body,
                              contentType: "multipart/related; boundary=\(boundary)")
    }

    func update(_ id: String, _ content: Data) async throws {
        _ = try await request("PATCH", "https://www.googleapis.com/upload/drive/v3/files/\(id)?uploadType=media", body: content)
    }

    func delete(_ id: String) async throws { _ = try await request("DELETE", "https://www.googleapis.com/drive/v3/files/\(id)") }
}

/// Sync / backup / restore. Merge rules and failure safety are described in docs/SYNC.md:
/// download -> merge by stable id + HLC + tombstones -> safety copy -> apply atomically -> upload
/// with a revision check. Local data is never discarded on failure.
@MainActor
final class SyncManager: ObservableObject {
    enum Mode { case sync, backup, restore }
    @Published private(set) var running = false
    private weak var model: AppModel?
    private var pendingSoon: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func scheduleSoon() {
        pendingSoon?.cancel()
        pendingSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            if !Task.isCancelled { _ = await self?.run(.sync) }
        }
    }

    @discardableResult
    func run(_ mode: Mode, token given: String? = nil) async -> Result<String, Error> {
        guard let model, !running else { return .failure(SyncError.message("A sync is already running.")) }
        running = true
        defer { running = false }
        let token: String?
        if let given { token = given } else { token = await DriveAuth.silentToken() }
        guard let token else {
            model.settings.lastSyncStatus = SyncError.needsSignIn.localizedDescription
            return .failure(SyncError.needsSignIn)
        }
        do {
            let message = try await runWithToken(mode, DriveClient(token: token), model)
            model.settings.lastSyncAt = Date()
            model.settings.lastSyncStatus = message
            return .success(message)
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach Google Drive. Your tasks on this device are safe."
            model.settings.lastSyncStatus = "Last attempt failed: " + text
            return .failure(error)
        }
    }

    private func runWithToken(_ mode: Mode, _ drive: DriveClient, _ model: AppModel) async throws -> String {
        for _ in 0..<3 {
            let files = try await drive.findSyncFiles()
            var remote: [String: SyncRecord] = [:]
            for f in files {
                for r in try SnapshotCodec.decode(try await drive.download(f.id)).records {
                    remote[r.key] = remote[r.key].map { SyncMerger.winner($0, r) } ?? r
                }
            }
            let changed = applyMerge(remote: Array(remote.values), model: model)
            let local = SyncMapping.records(model.store.load())
            let merge = SyncMerger.merge(local: local, remote: Array(remote.values), nowMillis: nowMillis())
            if mode != .restore && (merge.remoteNeedsUpdate || files.isEmpty || files.count > 1 || mode == .backup) {
                let content = SnapshotCodec.encode(SyncSnapshot(generatedBy: model.store.deviceId, generatedAt: nowMillis(), records: merge.merged))
                if let primary = files.first {
                    let latest = try await drive.findSyncFiles().first { $0.id == primary.id }
                    if latest?.headRevisionId != primary.headRevisionId { continue } // someone else uploaded; merge again
                    try await drive.update(primary.id, content)
                    for extra in files.dropFirst() { try? await drive.delete(extra.id) }
                } else {
                    try await drive.create(content)
                }
            }
            switch mode {
            case .restore: return "Restored from Google Drive (\(changed) change\(changed == 1 ? "" : "s"))"
            case .backup: return "Backed up to Google Drive"
            case .sync: return "Synced" + (changed > 0 ? " · \(changed) update\(changed == 1 ? "" : "s") received" : "")
            }
        }
        throw SyncError.message("Another device kept syncing at the same time. Try again in a moment.")
    }

    /// Merges remote records into the local store in one write. Returns how many local rows changed.
    @discardableResult
    func applyMerge(remote: [SyncRecord], model: AppModel) -> Int {
        let before = model.store.load()
        let merge = SyncMerger.merge(local: SyncMapping.records(before), remote: remote, nowMillis: nowMillis())
        guard !merge.changedLocally.isEmpty || !merge.purgeLocally.isEmpty else { return 0 }
        writeSafetyCopy(before)
        model.perform(fromSync: true) { db, _ in SyncMapping.apply(merge.changedLocally, purge: merge.purgeLocally, to: &db) }
        return merge.changedLocally.count
    }

    private func writeSafetyCopy(_ db: Database) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("safety")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(db).write(to: dir.appendingPathComponent("before-\(nowMillis()).json"))
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted(by: >)
        for f in files.dropFirst(3) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
    }

    private func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: local backup file (Files app via fileExporter / fileImporter; no permissions needed)

    func exportDocument() -> BackupDocument {
        guard let model else { return BackupDocument(data: Data()) }
        let records = SyncMapping.records(model.store.load())
        return BackupDocument(data: SnapshotCodec.encode(SyncSnapshot(generatedBy: model.store.deviceId, generatedAt: nowMillis(), records: records)))
    }

    func importBackup(_ url: URL) -> String {
        guard let model else { return "Import failed" }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let snap = try SnapshotCodec.decode(try Data(contentsOf: url))
            let n = applyMerge(remote: snap.records, model: model)
            return "Imported backup (\(n) change\(n == 1 ? "" : "s"))"
        } catch {
            return "Import failed: \((error as? LocalizedError)?.errorDescription ?? "unreadable file"). Your tasks are unchanged."
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
