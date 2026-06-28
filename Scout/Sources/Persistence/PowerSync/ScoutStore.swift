import Foundation
import PowerSync

/// The local-first data layer over PowerSync's SQLite. Replaces PersistenceController/Core Data.
/// Reads are reactive (`watch` → AsyncThrowingStream); writes go to the local DB and (once a
/// backend connector is attached in P4) sync to Supabase. No cloud is required for P1–P3.
final class ScoutStore {
    static let shared = ScoutStore()

    let db: any PowerSyncDatabaseProtocol

    private init() {
        #if DEBUG
        let filename = "scout-dev.sqlite"
        #else
        let filename = "scout.sqlite"
        #endif
        db = PowerSyncDatabase(schema: ScoutSchema.schema, dbFilename: filename)
    }

    // MARK: - Reactive reads (live queries)

    func watchProjects() -> AsyncThrowingStream<[ProjectRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM projects WHERE deleted_at IS NULL ORDER BY created_at DESC",
            parameters: []
        ) { try ProjectRecord(cursor: $0) }
    }

    func watchLists(projectId: String) -> AsyncThrowingStream<[ListRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM location_lists WHERE project_id = ? AND deleted_at IS NULL ORDER BY panel_order, created_at",
            parameters: [projectId]
        ) { try ListRecord(cursor: $0) }
    }

    func watchPins(listId: String) -> AsyncThrowingStream<[PinRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM pins WHERE list_id = ? AND deleted_at IS NULL ORDER BY sort_order",
            parameters: [listId]
        ) { try PinRecord(cursor: $0) }
    }

    func watchScripts(projectId: String) -> AsyncThrowingStream<[ScriptRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM scripts WHERE project_id = ? ORDER BY sort_order",
            parameters: [projectId]
        ) { try ScriptRecord(cursor: $0) }
    }

    func watchHighlights(scriptId: String) -> AsyncThrowingStream<[HighlightRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM script_highlights WHERE script_id = ? ORDER BY range_start",
            parameters: [scriptId]
        ) { try HighlightRecord(cursor: $0) }
    }

    // MARK: - One-shot reads

    func allProjects() async throws -> [ProjectRecord] {
        try await db.getAll(
            sql: "SELECT * FROM projects WHERE deleted_at IS NULL ORDER BY created_at DESC",
            parameters: []
        ) { try ProjectRecord(cursor: $0) }
    }

    // MARK: - Writes

    @discardableResult
    func createProject(name: String) async throws -> String {
        let id = UUID().uuidString
        try await db.execute(
            sql: "INSERT INTO projects (id, name, notes, uncategorized_panel_order, created_at) VALUES (?, ?, '', 0, ?)",
            parameters: [id, name, ISO8601DateFormatter.string(Date())]
        )
        return id
    }

    func renameProject(id: String, name: String) async throws {
        try await db.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", parameters: [name, id])
    }

    /// Soft-delete (Trash). Cascades are handled by Postgres FKs on sync; locally we mark the row.
    func softDeleteProject(id: String) async throws {
        try await db.execute(
            sql: "UPDATE projects SET deleted_at = ? WHERE id = ?",
            parameters: [ISO8601DateFormatter.string(Date()), id]
        )
    }

    @discardableResult
    func createList(projectId: String, name: String, colorHex: String,
                    parentListId: String?, panelOrder: Int) async throws -> String {
        let id = UUID().uuidString
        try await db.execute(
            sql: """
            INSERT INTO location_lists (id, project_id, parent_list_id, name, color_hex, panel_order, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?)
            """,
            parameters: [id, projectId, parentListId as Any, name, colorHex, panelOrder, ISO8601DateFormatter.string(Date())]
        )
        return id
    }

    func setPinFlagged(id: String, flagged: Bool) async throws {
        try await db.execute(
            sql: "UPDATE pins SET is_flagged = ? WHERE id = ?",
            parameters: [flagged ? 1 : 0, id]
        )
    }

    /// Escape hatch for callers needing a custom statement during the migration.
    func execute(_ sql: String, _ parameters: [Any?] = []) async throws {
        try await db.execute(sql: sql, parameters: parameters)
    }
}
