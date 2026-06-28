import Foundation
import CoreData

/// One-time migration of the user's existing Core Data graph into the PowerSync local SQLite store
/// (migration plan P3). Idempotent on identity: every row keeps its Core Data `uuid.uuidString` as
/// its PowerSync primary key, so re-running imports the same ids (INSERT OR REPLACE) without dupes.
///
/// This reads the *raw* relationships (not the `live…` accessors) on purpose — trashed rows carry
/// their `deletedAt`, so the Trash is preserved verbatim across the migration.
enum CoreDataImporter {
    /// Returns the number of projects imported (0 if there was nothing to import).
    @discardableResult
    static func importAll(from context: NSManagedObjectContext, into store: ScoutStore = .shared) async throws -> Int {
        // Fetch the whole graph on the context's queue, snapshotting to Sendable value rows so the
        // PowerSync write transaction (which hops threads) never touches NSManagedObjects.
        let snapshot: GraphSnapshot = try await context.perform {
            let projects = try context.fetch(FetchDescriptor(ProjectData.self))
            return GraphSnapshot(projects: projects)
        }
        guard !snapshot.projects.isEmpty else { return 0 }

        try await store.transaction { tx in
            for p in snapshot.projects {
                try tx.execute(sql: projectSQL, parameters: p.params)
            }
            for l in snapshot.lists {
                try tx.execute(sql: listSQL, parameters: l.params)
            }
            for pin in snapshot.pins {
                try tx.execute(sql: ScoutStore.pinInsertSQL.replacingOccurrences(of: "INSERT INTO", with: "INSERT OR REPLACE INTO"),
                               parameters: pin)
            }
            for s in snapshot.scripts {
                try tx.execute(sql: scriptSQL, parameters: s.params)
            }
            for h in snapshot.highlights {
                try tx.execute(sql: highlightSQL, parameters: h.params)
            }
        }
        return snapshot.projects.count
    }

    // MARK: - SQL (INSERT OR REPLACE so re-import is idempotent)

    private static let projectSQL = """
    INSERT OR REPLACE INTO projects (id, name, notes, uncategorized_panel_order, created_at, deleted_at)
    VALUES (?, ?, ?, ?, ?, ?)
    """
    private static let listSQL = """
    INSERT OR REPLACE INTO location_lists (id, project_id, parent_list_id, name, color_hex, scene_type, panel_order, sort_order, created_at, deleted_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
    private static let scriptSQL = """
    INSERT OR REPLACE INTO scripts (id, project_id, name, raw_text, sort_order, imported_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """
    private static let highlightSQL = """
    INSERT OR REPLACE INTO script_highlights (id, script_id, list_id, range_start, range_length, excerpt, context_before, context_after, scene_heading, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """
}

// MARK: - Sendable snapshot built on the Core Data queue

/// A flattened, value-only copy of the whole Core Data graph, safe to hand to a background write
/// transaction. Built entirely inside `context.perform`.
private struct GraphSnapshot: @unchecked Sendable {
    let projects: [ProjectRow]
    let lists: [ListRow]
    let pins: [[Any?]]
    let scripts: [ScriptRow]
    let highlights: [HighlightRow]

    init(projects pds: [ProjectData]) {
        var projectRows: [ProjectRow] = []
        var listRows: [ListRow] = []
        var pinRows: [[Any?]] = []
        var scriptRows: [ScriptRow] = []
        var highlightRows: [HighlightRow] = []

        for p in pds {
            let pid = p.uuid.uuidString
            projectRows.append(ProjectRow(p, id: pid))
            for l in p.lists { listRows.append(ListRow(l, projectId: pid)) }
            for pin in p.importedPhotos { pinRows.append(Self.pinParams(pin, listId: nil, projectId: pid)) }
            for s in p.scripts {
                let sid = s.uuid.uuidString
                scriptRows.append(ScriptRow(s, id: sid, projectId: pid))
                for h in s.highlights { highlightRows.append(HighlightRow(h, scriptId: sid)) }
            }
            // Pins live under lists; walk every list (incl. nested) for the project.
            for l in p.lists {
                for pin in l.pins { pinRows.append(Self.pinParams(pin, listId: l.uuid.uuidString, projectId: nil)) }
            }
        }
        projects = projectRows
        lists = listRows
        pins = pinRows
        scripts = scriptRows
        highlights = highlightRows
    }

    private static func iso(_ d: Date?) -> Any? { d.map { ISO8601DateFormatter.string($0) } as Any }

    static func pinParams(_ pin: PinnedLocationData, listId: String?, projectId: String?) -> [Any?] {
        [
            pin.uuid.uuidString, listId as Any, projectId as Any, pin.name, pin.notes,
            pin.latitude, pin.longitude, pin.hasGPS ? 1 : 0, pin.gpsFromTimeline ? 1 : 0,
            pin.isFlagged ? 1 : 0, pin.rotationQuarterTurns, pin.aspectRatio, pin.panelOrder,
            pin.sortOrder, pin.statusRaw, pin.imageSourceRaw as Any, pin.imageURL as Any,
            pin.googlePlaceId as Any, pin.googleMapsURLString as Any, pin.sourceURLString as Any,
            pin.originalFilename as Any, encode(pin.photoFiles), encode(pin.thumbnailFiles),
            iso(pin.dateTaken), ISO8601DateFormatter.string(pin.createdAt), iso(pin.deletedAt),
        ]
    }
    private static func encode(_ a: [String]) -> String {
        guard let d = try? JSONEncoder().encode(a), let s = String(data: d, encoding: .utf8) else { return "[]" }
        return s
    }
}

private struct ProjectRow {
    let params: [Any?]
    init(_ p: ProjectData, id: String) {
        params = [id, p.name, p.notes, p.uncategorizedPanelOrder,
                  ISO8601DateFormatter.string(p.createdAt),
                  p.deletedAt.map { ISO8601DateFormatter.string($0) } as Any]
    }
}

private struct ListRow {
    let params: [Any?]
    init(_ l: LocationListData, projectId: String) {
        params = [l.uuid.uuidString, projectId, l.parentList?.uuid.uuidString as Any, l.name,
                  l.colorHex, l.sceneType as Any, l.panelOrder, l.sortOrder,
                  ISO8601DateFormatter.string(l.createdAt),
                  l.deletedAt.map { ISO8601DateFormatter.string($0) } as Any]
    }
}

private struct ScriptRow {
    let params: [Any?]
    init(_ s: ScriptData, id: String, projectId: String) {
        params = [id, projectId, s.name, s.rawText, s.sortOrder,
                  ISO8601DateFormatter.string(s.importedAt), ISO8601DateFormatter.string(s.updatedAt)]
    }
}

private struct HighlightRow {
    let params: [Any?]
    init(_ h: ScriptHighlight, scriptId: String) {
        params = [h.uuid.uuidString, scriptId, h.list?.uuid.uuidString as Any, h.rangeStart,
                  h.rangeLength, h.excerpt, h.contextBefore, h.contextAfter, h.sceneHeading as Any,
                  ISO8601DateFormatter.string(h.createdAt)]
    }
}
