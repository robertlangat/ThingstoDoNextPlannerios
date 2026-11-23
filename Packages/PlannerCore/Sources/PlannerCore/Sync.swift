import Foundation

/// Hybrid logical clock: `(millis << 16) | counter`. Same encoding as the Android app.
public final class HybridLogicalClock: @unchecked Sendable {
    private var last: Int64
    private let wall: () -> Int64
    private let lock = NSLock()

    public init(last: Int64 = 0, wall: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.last = last; self.wall = wall
    }

    public func now() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let physical = wall() << 16
        last = physical > last ? physical : last + 1
        return last
    }

    public func observe(_ remote: Int64) {
        lock.lock(); defer { lock.unlock() }
        if remote > last { last = remote }
    }

    public static func millis(of version: Int64) -> Int64 { version >> 16 }
}

public struct SyncRecord: Hashable, Sendable {
    public var type: String
    public var id: String
    public var version: Int64
    public var deviceId: String
    public var deleted: Bool
    public var data: [String: JSONValue]
    public var seenDeleteVersion: Int64

    public init(type: String, id: String, version: Int64, deviceId: String, deleted: Bool, data: [String: JSONValue], seenDeleteVersion: Int64 = 0) {
        self.type = type; self.id = id; self.version = version; self.deviceId = deviceId
        self.deleted = deleted; self.data = data; self.seenDeleteVersion = seenDeleteVersion
    }

    public var key: String { "\(type):\(id)" }
}

public struct SyncSnapshot: Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var generatedBy: String
    public var generatedAt: Int64
    public var records: [SyncRecord]
    public init(schemaVersion: Int = SyncSnapshot.currentSchema, generatedBy: String, generatedAt: Int64, records: [SyncRecord]) {
        self.schemaVersion = schemaVersion; self.generatedBy = generatedBy; self.generatedAt = generatedAt; self.records = records
    }
}

public struct MergeResult: Sendable {
    public var merged: [SyncRecord]
    public var changedLocally: [SyncRecord]
    /// Keys to delete locally (old tombstones purged).
    public var purgeLocally: Set<String>
    public var remoteNeedsUpdate: Bool
}

/// Merge rules (docs/SYNC.md): match by id; live vs live = higher version (tie: deviceId);
/// tombstone vs live = deletion wins unless the live edit was made after seeing that deletion;
/// tombstones are kept for 180 days.
public enum SyncMerger {
    public static let tombstoneRetentionMillis: Int64 = 180 * 24 * 60 * 60 * 1000

    public static func sameRevision(_ a: SyncRecord, _ b: SyncRecord) -> Bool {
        a.version == b.version && a.deviceId == b.deviceId && a.deleted == b.deleted && a.seenDeleteVersion == b.seenDeleteVersion
    }

    public static func winner(_ a: SyncRecord, _ b: SyncRecord) -> SyncRecord {
        if a.deleted != b.deleted {
            let tomb = a.deleted ? a : b
            let live = a.deleted ? b : a
            return (live.version > tomb.version && live.seenDeleteVersion >= tomb.version) ? live : tomb
        }
        if a.version != b.version { return a.version > b.version ? a : b }
        return a.deviceId >= b.deviceId ? a : b
    }

    public static func merge(local: [SyncRecord], remote: [SyncRecord], nowMillis: Int64,
                             retention: Int64 = tombstoneRetentionMillis) -> MergeResult {
        var l: [String: SyncRecord] = [:]; local.forEach { l[$0.key] = $0 }
        var r: [String: SyncRecord] = [:]
        for rec in remote { r[rec.key] = r[rec.key].map { winner($0, rec) } ?? rec }
        var keys: [String] = []
        var seen = Set<String>()
        for k in local.map(\.key) + remote.map(\.key) where !seen.contains(k) { seen.insert(k); keys.append(k) }

        var merged: [SyncRecord] = []
        var changed: [SyncRecord] = []
        var purge = Set<String>()
        var remoteNeedsUpdate = false
        let purgeBefore = nowMillis - retention
        for k in keys {
            let lv = l[k], rv = r[k]
            let w: SyncRecord
            switch (lv, rv) {
            case let (a?, b?): w = winner(a, b)
            case let (a?, nil): w = a
            case let (nil, b?): w = b
            default: continue
            }
            if w.deleted && HybridLogicalClock.millis(of: w.version) < purgeBefore {
                if lv != nil { purge.insert(k) }
                if rv != nil { remoteNeedsUpdate = true }
                continue
            }
            merged.append(w)
            if lv == nil || !sameRevision(lv!, w) { changed.append(w) }
            if rv == nil || !sameRevision(rv!, w) { remoteNeedsUpdate = true }
        }
        return MergeResult(merged: merged, changedLocally: changed, purgeLocally: purge, remoteNeedsUpdate: remoteNeedsUpdate)
    }
}

public enum SnapshotCodec {
    public enum CodecError: Error, LocalizedError {
        case unreadable, newerSchema(Int)
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "Not a Things to Do Next Planner backup"
            case .newerSchema(let s): return "Backup was made by a newer version of the app (schema \(s)). Please update."
            }
        }
    }

    public static func encode(_ s: SyncSnapshot) -> Data {
        let records: [JSONValue] = s.records.map {
            .object([
                "type": .string($0.type), "id": .string($0.id), "version": .int(Int($0.version)),
                "deviceId": .string($0.deviceId), "deleted": .bool($0.deleted),
                "seenDeleteVersion": .int(Int($0.seenDeleteVersion)), "data": .object($0.data),
            ])
        }
        let root = JSONValue.object([
            "schemaVersion": .int(s.schemaVersion), "generatedBy": .string(s.generatedBy),
            "generatedAt": .int(Int(s.generatedAt)), "records": .array(records),
        ])
        return Data(root.encodedString().utf8)
    }

    public static func decode(_ data: Data) throws -> SyncSnapshot {
        guard let root = (try? JSONValue.parse(data))?.object, let schema = root["schemaVersion"]?.int else { throw CodecError.unreadable }
        if schema > SyncSnapshot.currentSchema { throw CodecError.newerSchema(schema) }
        let records: [SyncRecord] = (root["records"]?.array ?? []).compactMap { v in
            guard let o = v.object, let type = o["type"]?.string, let id = o["id"]?.string else { return nil }
            return SyncRecord(type: type, id: id, version: Int64(o["version"]?.int ?? 0), deviceId: o["deviceId"]?.string ?? "",
                              deleted: o["deleted"]?.bool ?? false, data: o["data"]?.object ?? [:],
                              seenDeleteVersion: Int64(o["seenDeleteVersion"]?.int ?? 0))
        }
        return SyncSnapshot(schemaVersion: schema, generatedBy: root["generatedBy"]?.string ?? "",
                            generatedAt: Int64(root["generatedAt"]?.int ?? 0), records: records)
    }
}
