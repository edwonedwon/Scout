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
                case .put:
                    // PUT carries the full row → upsert (insert-or-replace) keyed on the primary key.
                    var row = Self.json(from: entry.opDataTyped)
                    row["id"] = .string(entry.id)
                    try await table.upsert(row, onConflict: "id").execute()
                case .patch:
                    // PATCH carries ONLY the changed columns. Must be a real UPDATE, not an upsert:
                    // an upsert runs INSERT…ON CONFLICT, and the RLS WITH CHECK then sees a partial
                    // row (e.g. a reorder has no project_id) and rejects it (42501). UPDATE keeps the
                    // existing row's other columns, so the ownership check passes.
                    let row = Self.json(from: entry.opDataTyped)
                    try await table.update(row).eq("id", value: entry.id).execute()
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
    /// Attach the backend and start syncing. Call after the user signs in (and the PowerSync
    /// instance URL is configured). Safe to call repeatedly — a no-op when sync isn't set up.
    func connectIfPossible() async {
        guard SupabaseConfig.syncEnabled, let client = SupabaseService.client else { return }
        do {
            try await db.connect(connector: SupabaseConnector(client: client), options: nil)
            await Self.log("connected")
        } catch {
            await Self.log("connect failed: \(error)", .error)
        }
    }

    @MainActor private static func log(_ s: String, _ level: DebugEntry.Level = .info) {
        DebugLogger.shared.log(s, level: level, tag: "Sync")
    }
}
