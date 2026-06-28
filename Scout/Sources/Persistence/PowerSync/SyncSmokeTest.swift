#if DEBUG
import Foundation
import Supabase

/// End-to-end sync proof (migration plan P2 verification — run before investing more in the UI).
///
/// Launch a **signed-in** build with the `SCOUT_SYNC_SMOKE` environment variable set. The test
/// drives a real round-trip through PowerSync + Supabase in both directions and prints a PASS/FAIL
/// report to the console:
///   • UPLOAD   — create a project locally, confirm the row appears in Supabase (write queue → PostgREST).
///   • DOWNLOAD — insert a project server-side, confirm it syncs down to the device (sync rules → SQLite).
/// Both markers are cleaned up afterwards (local + server), so it leaves no residue.
enum SyncSmokeTest {
    static func run() async {
        // Write to stderr (unbuffered) so output is visible live when stdout is redirected to a file.
        func log(_ s: String) { FileHandle.standardError.write(Data("[SyncSmoke] \(s)\n".utf8)) }
        log("starting…")

        guard SupabaseConfig.syncEnabled, let client = SupabaseService.client else {
            log("FAIL: sync not configured — SupabaseConfig.syncEnabled=\(SupabaseConfig.syncEnabled)")
            return
        }
        guard let session = try? await client.auth.session else {
            log("FAIL: not signed in. Run on a device/Mac with a saved Supabase session.")
            return
        }
        log("signed in as \(session.user.email ?? session.user.id.uuidString)")

        let store = ScoutStore.shared
        await store.connectIfPossible()
        let connected = await poll(timeout: 25) { store.db.currentStatus.connected }
        log("powersync connected=\(connected), hasSynced=\(store.db.currentStatus.hasSynced ?? false)")
        if !connected {
            log("FAIL: PowerSync never connected. Check the instance URL + Client Auth (JWKS) in the dashboard.")
            return
        }

        // --- Direction 1: local write → Supabase (upload) ---
        var uploadOK = false
        var uploadId: String?
        do {
            let marker = "smoke-up-\(UUID().uuidString.prefix(8))"
            let id = try await store.createProject(name: marker)
            uploadId = id
            log("UPLOAD: created local project \(id); waiting for it to reach Supabase…")
            uploadOK = await poll(timeout: 30) {
                let rows: [SmokeRow] = try await client.from("projects")
                    .select("id,name").eq("id", value: id).execute().value
                return !rows.isEmpty
            }
            log(uploadOK ? "UPLOAD ✅ PASS — row reached Supabase" : "UPLOAD ❌ FAIL — not in Supabase within 30s")
        } catch {
            log("UPLOAD ❌ FAIL: \(error)")
        }

        // --- Direction 2: Supabase insert → local (download via sync rules) ---
        var downloadOK = false
        let dlId = UUID().uuidString
        do {
            let marker = "smoke-dl-\(UUID().uuidString.prefix(8))"
            // owner_id defaults to auth.uid() server-side, which keeps it inside the user's sync stream.
            let row: [String: AnyJSON] = ["id": .string(dlId), "name": .string(marker)]
            try await client.from("projects").insert(row).execute()
            log("DOWNLOAD: inserted server project \(dlId); waiting for it to sync to the device…")
            downloadOK = await poll(timeout: 30) {
                try await store.allProjects().contains { $0.id == dlId }
            }
            log(downloadOK ? "DOWNLOAD ✅ PASS — row synced to device" : "DOWNLOAD ❌ FAIL — not on device within 30s")
        } catch {
            log("DOWNLOAD ❌ FAIL: \(error)")
        }

        // Cleanup both markers, locally and on the server.
        if let uploadId { try? await store.purgeProject(id: uploadId) }
        try? await store.purgeProject(id: dlId)
        try? await client.from("projects").delete().eq("id", value: dlId).execute()

        log("RESULT — upload=\(uploadOK ? "PASS" : "FAIL") download=\(downloadOK ? "PASS" : "FAIL")")
        log("done.")
    }

    private struct SmokeRow: Decodable { let id: String; let name: String }

    /// Poll `check` once a second until it returns true or the timeout elapses.
    private static func poll(timeout: TimeInterval, _ check: @escaping () async throws -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await check()) == true { return true }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }
}
#endif
