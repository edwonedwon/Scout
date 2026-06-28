import Foundation
import PowerSync

/// The local-first data layer over PowerSync's SQLite. Replaces PersistenceController/Core Data.
/// Reads are reactive (`watch` → AsyncThrowingStream); writes go to the local DB and (once a
/// backend connector is attached in P4) sync to Supabase. No cloud is required for P1–P3.
///
/// Conventions used throughout:
///   • ids are client-generated UUID strings (offline-safe, conflict-free on identity),
///   • timestamps are ISO-8601 TEXT (`now()` helper), booleans INTEGER 0/1,
///   • soft-delete sets `deleted_at`; the row survives until purged (mirrors the Core Data Trash).
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

    static func newID() -> String { UUID().uuidString }
    private func now() -> String { ISO8601DateFormatter.string(Date()) }

    // MARK: - Reactive reads (live queries)

    func watchProjects() -> AsyncThrowingStream<[ProjectRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM projects WHERE deleted_at IS NULL ORDER BY created_at DESC",
            parameters: []
        ) { try ProjectRecord(cursor: $0) }
    }

    /// Top-level lists in a project (no parent). Folders/children come via `watchChildLists`.
    func watchLists(projectId: String) -> AsyncThrowingStream<[ListRecord], Error> {
        try! db.watch(
            sql: """
            SELECT * FROM location_lists
            WHERE project_id = ? AND parent_list_id IS NULL AND deleted_at IS NULL
            ORDER BY panel_order, created_at
            """,
            parameters: [projectId]
        ) { try ListRecord(cursor: $0) }
    }

    /// Every list in a project (top-level + nested), so callers can build the tree in one pass.
    func watchAllLists(projectId: String) -> AsyncThrowingStream<[ListRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM location_lists WHERE project_id = ? AND deleted_at IS NULL ORDER BY panel_order, created_at",
            parameters: [projectId]
        ) { try ListRecord(cursor: $0) }
    }

    func watchChildLists(parentListId: String) -> AsyncThrowingStream<[ListRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM location_lists WHERE parent_list_id = ? AND deleted_at IS NULL ORDER BY panel_order, created_at",
            parameters: [parentListId]
        ) { try ListRecord(cursor: $0) }
    }

    func watchPins(listId: String) -> AsyncThrowingStream<[PinRecord], Error> {
        try! db.watch(
            sql: "SELECT * FROM pins WHERE list_id = ? AND deleted_at IS NULL ORDER BY sort_order",
            parameters: [listId]
        ) { try PinRecord(cursor: $0) }
    }

    /// Loose photos imported straight into a project (no list).
    func watchProjectPhotos(projectId: String) -> AsyncThrowingStream<[PinRecord], Error> {
        try! db.watch(
            sql: """
            SELECT * FROM pins
            WHERE owning_project_id = ? AND list_id IS NULL AND deleted_at IS NULL
            ORDER BY panel_order, sort_order
            """,
            parameters: [projectId]
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

    func pins(in listId: String) async throws -> [PinRecord] {
        try await db.getAll(
            sql: "SELECT * FROM pins WHERE list_id = ? AND deleted_at IS NULL ORDER BY sort_order",
            parameters: [listId]
        ) { try PinRecord(cursor: $0) }
    }

    func projectCount() async throws -> Int {
        let rows = try await db.getAll(
            sql: "SELECT COUNT(*) AS c FROM projects",
            parameters: []
        ) { Int(try $0.getInt64(name: "c")) }
        return rows.first ?? 0
    }

    // MARK: - Project writes

    @discardableResult
    func createProject(name: String, notes: String = "") async throws -> String {
        let id = Self.newID()
        try await db.execute(
            sql: "INSERT INTO projects (id, name, notes, uncategorized_panel_order, created_at) VALUES (?, ?, ?, 0, ?)",
            parameters: [id, name, notes, now()]
        )
        return id
    }

    func renameProject(id: String, name: String) async throws {
        try await db.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", parameters: [name, id])
    }

    func setProjectNotes(id: String, notes: String) async throws {
        try await db.execute(sql: "UPDATE projects SET notes = ? WHERE id = ?", parameters: [notes, id])
    }

    func setUncategorizedPanelOrder(projectId: String, order: Int) async throws {
        try await db.execute(
            sql: "UPDATE projects SET uncategorized_panel_order = ? WHERE id = ?",
            parameters: [order, projectId]
        )
    }

    /// Soft-delete (Trash). Postgres FK cascade reaches children on sync; locally we mark the row.
    func softDeleteProject(id: String) async throws {
        try await db.execute(sql: "UPDATE projects SET deleted_at = ? WHERE id = ?", parameters: [now(), id])
    }

    func restoreProject(id: String) async throws {
        try await db.execute(sql: "UPDATE projects SET deleted_at = NULL WHERE id = ?", parameters: [id])
    }

    /// Permanent delete. FKs cascade to lists/pins/scripts on the synced Postgres; locally we
    /// delete the whole subtree explicitly so the device matches without waiting for a round-trip.
    func purgeProject(id: String) async throws {
        try await db.writeTransaction { tx in
            try tx.execute(sql: "DELETE FROM script_highlights WHERE script_id IN (SELECT id FROM scripts WHERE project_id = ?)", parameters: [id])
            try tx.execute(sql: "DELETE FROM scripts WHERE project_id = ?", parameters: [id])
            try tx.execute(sql: "DELETE FROM pins WHERE owning_project_id = ? OR list_id IN (SELECT id FROM location_lists WHERE project_id = ?)", parameters: [id, id])
            try tx.execute(sql: "DELETE FROM location_lists WHERE project_id = ?", parameters: [id])
            try tx.execute(sql: "DELETE FROM project_members WHERE project_id = ?", parameters: [id])
            try tx.execute(sql: "DELETE FROM projects WHERE id = ?", parameters: [id])
        }
    }

    // MARK: - List writes

    @discardableResult
    func createList(projectId: String, name: String, colorHex: String,
                    parentListId: String? = nil, sceneType: String? = nil,
                    panelOrder: Int = 0, sortOrder: Int = 0) async throws -> String {
        let id = Self.newID()
        try await db.execute(
            sql: """
            INSERT INTO location_lists (id, project_id, parent_list_id, name, color_hex, scene_type, panel_order, sort_order, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [id, projectId, parentListId as Any, name, colorHex, sceneType as Any, panelOrder, sortOrder, now()]
        )
        return id
    }

    func renameList(id: String, name: String) async throws {
        try await db.execute(sql: "UPDATE location_lists SET name = ? WHERE id = ?", parameters: [name, id])
    }

    func setListColor(id: String, colorHex: String) async throws {
        try await db.execute(sql: "UPDATE location_lists SET color_hex = ? WHERE id = ?", parameters: [colorHex, id])
    }

    func setListSceneType(id: String, sceneType: String?) async throws {
        try await db.execute(sql: "UPDATE location_lists SET scene_type = ? WHERE id = ?", parameters: [sceneType as Any, id])
    }

    func setListPanelOrder(id: String, order: Int) async throws {
        try await db.execute(sql: "UPDATE location_lists SET panel_order = ? WHERE id = ?", parameters: [order, id])
    }

    /// Re-parent a list (drag into/out of a folder). Pass nil to move it back to top level.
    func setListParent(id: String, parentListId: String?) async throws {
        try await db.execute(sql: "UPDATE location_lists SET parent_list_id = ? WHERE id = ?", parameters: [parentListId as Any, id])
    }

    func softDeleteList(id: String) async throws {
        try await db.execute(sql: "UPDATE location_lists SET deleted_at = ? WHERE id = ?", parameters: [now(), id])
    }

    func restoreList(id: String) async throws {
        try await db.execute(sql: "UPDATE location_lists SET deleted_at = NULL WHERE id = ?", parameters: [id])
    }

    // MARK: - Pin writes

    /// Insert a pin from a fully-formed record (used by import + new-pin flows). Honors the id on
    /// the record so callers can pre-allocate it (e.g. to name photo files before insert).
    @discardableResult
    func insertPin(_ p: PinRecord) async throws -> String {
        try await db.execute(sql: Self.pinInsertSQL, parameters: Self.pinParams(p))
        return p.id
    }

    func setPinFlagged(id: String, flagged: Bool) async throws {
        try await db.execute(sql: "UPDATE pins SET is_flagged = ? WHERE id = ?", parameters: [flagged ? 1 : 0, id])
    }

    func setPinRotation(id: String, quarterTurns: Int) async throws {
        try await db.execute(sql: "UPDATE pins SET rotation_quarter_turns = ? WHERE id = ?", parameters: [quarterTurns, id])
    }

    func renamePin(id: String, name: String) async throws {
        try await db.execute(sql: "UPDATE pins SET name = ? WHERE id = ?", parameters: [name, id])
    }

    func setPinNotes(id: String, notes: String) async throws {
        try await db.execute(sql: "UPDATE pins SET notes = ? WHERE id = ?", parameters: [notes, id])
    }

    func setPinStatus(id: String, statusRaw: String) async throws {
        try await db.execute(sql: "UPDATE pins SET status_raw = ? WHERE id = ?", parameters: [statusRaw, id])
    }

    func setPinSortOrder(id: String, order: Int) async throws {
        try await db.execute(sql: "UPDATE pins SET sort_order = ? WHERE id = ?", parameters: [order, id])
    }

    /// Move a pin into a list (or, with listId nil + a projectId, into the project's loose photos).
    func movePin(id: String, toList listId: String?, owningProjectId: String? = nil, sortOrder: Int? = nil) async throws {
        if let sortOrder {
            try await db.execute(
                sql: "UPDATE pins SET list_id = ?, owning_project_id = ?, sort_order = ? WHERE id = ?",
                parameters: [listId as Any, owningProjectId as Any, sortOrder, id]
            )
        } else {
            try await db.execute(
                sql: "UPDATE pins SET list_id = ?, owning_project_id = ? WHERE id = ?",
                parameters: [listId as Any, owningProjectId as Any, id]
            )
        }
    }

    func setPinPhotoFiles(id: String, photoFiles: [String], thumbnailFiles: [String]) async throws {
        try await db.execute(
            sql: "UPDATE pins SET photo_files = ?, thumbnail_files = ? WHERE id = ?",
            parameters: [encodeJSON(photoFiles), encodeJSON(thumbnailFiles), id]
        )
    }

    func softDeletePin(id: String) async throws {
        try await db.execute(sql: "UPDATE pins SET deleted_at = ? WHERE id = ?", parameters: [now(), id])
    }

    func restorePin(id: String) async throws {
        try await db.execute(sql: "UPDATE pins SET deleted_at = NULL WHERE id = ?", parameters: [id])
    }

    // MARK: - Script writes

    @discardableResult
    func createScript(projectId: String, name: String, rawText: String, sortOrder: Int = 0) async throws -> String {
        let id = Self.newID()
        let ts = now()
        try await db.execute(
            sql: "INSERT INTO scripts (id, project_id, name, raw_text, sort_order, imported_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            parameters: [id, projectId, name, rawText, sortOrder, ts, ts]
        )
        return id
    }

    func updateScriptText(id: String, rawText: String) async throws {
        try await db.execute(
            sql: "UPDATE scripts SET raw_text = ?, updated_at = ? WHERE id = ?",
            parameters: [rawText, now(), id]
        )
    }

    func renameScript(id: String, name: String) async throws {
        try await db.execute(sql: "UPDATE scripts SET name = ? WHERE id = ?", parameters: [name, id])
    }

    func setScriptSortOrder(id: String, order: Int) async throws {
        try await db.execute(sql: "UPDATE scripts SET sort_order = ? WHERE id = ?", parameters: [order, id])
    }

    func deleteScript(id: String) async throws {
        try await db.writeTransaction { tx in
            try tx.execute(sql: "DELETE FROM script_highlights WHERE script_id = ?", parameters: [id])
            try tx.execute(sql: "DELETE FROM scripts WHERE id = ?", parameters: [id])
        }
    }

    // MARK: - Highlight writes

    @discardableResult
    func createHighlight(scriptId: String, listId: String?, rangeStart: Int, rangeLength: Int,
                         excerpt: String, contextBefore: String = "", contextAfter: String = "",
                         sceneHeading: String? = nil) async throws -> String {
        let id = Self.newID()
        try await db.execute(
            sql: """
            INSERT INTO script_highlights (id, script_id, list_id, range_start, range_length, excerpt, context_before, context_after, scene_heading, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            parameters: [id, scriptId, listId as Any, rangeStart, rangeLength, excerpt, contextBefore, contextAfter, sceneHeading as Any, now()]
        )
        return id
    }

    /// Assign (or clear) the list a script section maps to.
    func setHighlightList(id: String, listId: String?) async throws {
        try await db.execute(sql: "UPDATE script_highlights SET list_id = ? WHERE id = ?", parameters: [listId as Any, id])
    }

    func deleteHighlight(id: String) async throws {
        try await db.execute(sql: "DELETE FROM script_highlights WHERE id = ?", parameters: [id])
    }

    // MARK: - Escape hatch / bulk

    /// Escape hatch for callers needing a custom statement during the migration.
    func execute(_ sql: String, _ parameters: [Any?] = []) async throws {
        try await db.execute(sql: sql, parameters: parameters)
    }

    /// Run several writes atomically (used by the one-time Core Data import).
    func transaction(_ body: @Sendable @escaping (any Transaction) throws -> Void) async throws {
        try await db.writeTransaction { tx in try body(tx) }
    }

    // MARK: - Shared pin INSERT (used by insertPin + import)

    static let pinInsertSQL = """
    INSERT INTO pins (
        id, list_id, owning_project_id, name, notes, latitude, longitude, has_gps, gps_from_timeline,
        is_flagged, rotation_quarter_turns, aspect_ratio, panel_order, sort_order, status_raw,
        image_source_raw, image_url, google_place_id, google_maps_url, source_url, original_filename,
        photo_files, thumbnail_files, date_taken, created_at, deleted_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    static func pinParams(_ p: PinRecord) -> [Any?] {
        [
            p.id, p.listId as Any, p.owningProjectId as Any, p.name, p.notes, p.latitude, p.longitude,
            p.hasGPS ? 1 : 0, p.gpsFromTimeline ? 1 : 0, p.isFlagged ? 1 : 0, p.rotationQuarterTurns,
            p.aspectRatio, p.panelOrder, p.sortOrder, p.statusRaw, p.imageSourceRaw as Any,
            p.imageURL as Any, p.googlePlaceId as Any, p.googleMapsURL as Any, p.sourceURL as Any,
            p.originalFilename as Any, encodeJSON(p.photoFiles), encodeJSON(p.thumbnailFiles),
            p.dateTaken.map { ISO8601DateFormatter.string($0) } as Any,
            ISO8601DateFormatter.string(p.createdAt),
            p.deletedAt.map { ISO8601DateFormatter.string($0) } as Any,
        ]
    }
}

private func encodeJSON(_ arr: [String]) -> String {
    guard let d = try? JSONEncoder().encode(arr), let s = String(data: d, encoding: .utf8) else { return "[]" }
    return s
}
