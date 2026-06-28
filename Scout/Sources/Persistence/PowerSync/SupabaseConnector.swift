import Foundation
import PowerSync
import ScoutKit
import Supabase

/// Bridges PowerSync's sync engine to the Supabase backend (migration plan P4):
///   • `fetchCredentials` hands PowerSync the current Supabase access token + instance URL,
///   • `uploadData` replays the local write queue (CRUD batch) against Postgres via PostgREST.
///
/// Last-write-wins is PowerSync's default; conflict-free identity is guaranteed because every row
/// uses a client-generated UUID primary key.
struct SupabaseConnector: PowerSyncBackendConnectorProtocol {
    let client: SupabaseClient

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        // Returns nil when signed out → PowerSync stays disconnected (no anonymous sync).
        guard let session = try? await client.auth.session else { return nil }
        return PowerSyncCredentials(endpoint: SupabaseConfig.powerSyncURL, token: session.accessToken)
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let batch = try await database.getCrudBatch() else { return }

        await Self.log("uploadData: flushing \(batch.crud.count) queued change(s)…")
        for entry in batch.crud {
            let table = client.from(entry.table)
            do {
                switch entry.op {
                case .put, .patch:
                    // PowerSync gives the full row for PUT and the changed columns for PATCH; in both
                    // cases an upsert keyed on the primary key is correct and idempotent.
                    var row = Self.json(from: entry.opDataTyped)
                    row["id"] = .string(entry.id)
                    try await table.upsert(row, onConflict: "id").execute()
                case .delete:
                    try await table.delete().eq("id", value: entry.id).execute()
                }
            } catch {
                // Surface the *exact* row the backend rejected — PowerSync otherwise swallows this
                // and retries the same batch forever, so nothing behind it in the queue uploads.
                await Self.log("upload REJECTED \(entry.op) \(entry.table)#\(entry.id): \(error)", .error)
                throw error
            }
        }

        // Only clear the queue once every change in the batch was accepted by the backend.
        try await batch.complete()
        await Self.log("uploadData: batch accepted ✅", .success)
    }

    @MainActor private static func log(_ s: String, _ level: DebugEntry.Level = .info) {
        DebugLogger.shared.log(s, level: level, tag: "Sync")
    }

    /// Convert PowerSync's typed JSON payload into Supabase's `AnyJSON`, preserving column types so
    /// Postgres receives real booleans/numbers (not stringified values).
    private static func json(from param: JsonParam?) -> [String: AnyJSON] {
        guard let param else { return [:] }
        return param.mapValues(anyJSON(from:))
    }

    private static func anyJSON(from value: JsonValue) -> AnyJSON {
        switch value {
        case .string(let s): return .string(s)
        case .int(let i):    return .integer(i)
        case .double(let d): return .double(d)
        case .bool(let b):   return .bool(b)
        case .null:          return .null
        case .array(let a):  return .array(a.map(anyJSON(from:)))
        case .object(let o): return .object(o.mapValues(anyJSON(from:)))
        }
    }
}

extension ScoutStore {
    /// Attach the backend and start syncing. Call after sign-in AND whenever the app returns to the
    /// foreground — iOS suspends the app and drops the streaming sync connection, which otherwise
    /// never resumes (so changes made elsewhere stop arriving). Skips the work when already
    /// connected, so it's cheap to call on every foreground.
    func connectIfPossible() async {
        guard SupabaseConfig.syncEnabled, let client = SupabaseService.client else { return }
        if db.currentStatus.connected { return }
        do {
            try await db.connect(connector: SupabaseConnector(client: client), options: nil)
            await MainActor.run { DebugLogger.shared.log("Sync connected.", level: .success, tag: "Sync") }
        } catch {
            await MainActor.run { DebugLogger.shared.log("Sync connect failed: \(error)", level: .error, tag: "Sync") }
        }
    }
}

/// Live, observable sync status for the UI (a connection pill, "last synced" text, etc.).
/// Mirrors PowerSync's `currentStatus` stream onto the main actor.
@MainActor
final class SyncStatusModel: ObservableObject {
    static let shared = SyncStatusModel()
    @Published private(set) var connected = false
    @Published private(set) var downloading = false
    @Published private(set) var uploading = false
    @Published private(set) var lastSyncedAt: Date? = nil
    private var task: Task<Void, Never>?

    /// Begin mirroring PowerSync's status stream. Idempotent.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await s in ScoutStore.shared.db.currentStatus.asFlow() {
                guard let self else { return }
                self.connected = s.connected
                self.downloading = s.downloading
                self.uploading = s.uploading
                self.lastSyncedAt = s.lastSyncedAt
            }
        }
    }
}
