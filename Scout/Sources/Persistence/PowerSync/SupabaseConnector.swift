import Foundation
import PowerSync
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

        for entry in batch.crud {
            let table = client.from(entry.table)
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
        }

        // Only clear the queue once every change in the batch was accepted by the backend.
        try await batch.complete()
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
        } catch {
            #if DEBUG
            print("[ScoutStore] connect failed: \(error)")
            #endif
        }
    }
}
