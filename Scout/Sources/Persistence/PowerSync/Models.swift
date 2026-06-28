import Foundation
import PowerSync

// Plain-value models backing the PowerSync local SQLite tables (replacing the Core Data
// NSManagedObject types). Each has a `cursor` initializer used by ScoutStore's query mappers.
// Timestamps are stored as ISO-8601 TEXT; booleans as INTEGER 0/1; photo lists as JSON TEXT.

private let iso = ISO8601DateFormatter()

private func parseDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    return iso.date(from: s) ?? ISO8601DateFormatter.withFractional.date(from: s)
}

extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private func parseStringArray(_ json: String?) -> [String] {
    guard let json, let data = json.data(using: .utf8),
          let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
    return arr
}

struct ProjectRecord: Identifiable, Hashable {
    var id: String
    var ownerId: String?
    var name: String
    var notes: String
    var uncategorizedPanelOrder: Int
    var createdAt: Date
    var deletedAt: Date?

    init(cursor c: SqlCursor) throws {
        id = try c.getString(name: "id")
        ownerId = try c.getStringOptional(name: "owner_id")
        name = (try c.getStringOptional(name: "name")) ?? ""
        notes = (try c.getStringOptional(name: "notes")) ?? ""
        uncategorizedPanelOrder = Int(try c.getInt64(name: "uncategorized_panel_order"))
        createdAt = parseDate(try c.getStringOptional(name: "created_at")) ?? Date()
        deletedAt = parseDate(try c.getStringOptional(name: "deleted_at"))
    }
}

struct ListRecord: Identifiable, Hashable {
    var id: String
    var projectId: String?
    var parentListId: String?
    var name: String
    var colorHex: String
    var sceneType: String?
    var panelOrder: Int
    var sortOrder: Int
    var createdAt: Date
    var deletedAt: Date?

    init(cursor c: SqlCursor) throws {
        id = try c.getString(name: "id")
        projectId = try c.getStringOptional(name: "project_id")
        parentListId = try c.getStringOptional(name: "parent_list_id")
        name = (try c.getStringOptional(name: "name")) ?? ""
        colorHex = (try c.getStringOptional(name: "color_hex")) ?? "#FF6B35"
        sceneType = try c.getStringOptional(name: "scene_type")
        panelOrder = Int(try c.getInt64(name: "panel_order"))
        sortOrder = Int(try c.getInt64(name: "sort_order"))
        createdAt = parseDate(try c.getStringOptional(name: "created_at")) ?? Date()
        deletedAt = parseDate(try c.getStringOptional(name: "deleted_at"))
    }
}

struct PinRecord: Identifiable, Hashable {
    var id: String
    var listId: String?
    var owningProjectId: String?
    var name: String
    var notes: String
    var latitude: Double
    var longitude: Double
    var hasGPS: Bool
    var gpsFromTimeline: Bool
    var isFlagged: Bool
    var rotationQuarterTurns: Int
    var aspectRatio: Double
    var panelOrder: Int
    var sortOrder: Int
    var statusRaw: String
    var imageSourceRaw: String?
    var imageURL: String?
    var googlePlaceId: String?
    var googleMapsURL: String?
    var sourceURL: String?
    var originalFilename: String?
    var photoFiles: [String]
    var thumbnailFiles: [String]
    var dateTaken: Date?
    var createdAt: Date
    var deletedAt: Date?

    init(id: String, listId: String?, owningProjectId: String?, name: String, notes: String,
         latitude: Double, longitude: Double, hasGPS: Bool, gpsFromTimeline: Bool, isFlagged: Bool,
         rotationQuarterTurns: Int, aspectRatio: Double, panelOrder: Int, sortOrder: Int,
         statusRaw: String, imageSourceRaw: String?, imageURL: String?, googlePlaceId: String?,
         googleMapsURL: String?, sourceURL: String?, originalFilename: String?, photoFiles: [String],
         thumbnailFiles: [String], dateTaken: Date?, createdAt: Date, deletedAt: Date?) {
        self.id = id; self.listId = listId; self.owningProjectId = owningProjectId; self.name = name
        self.notes = notes; self.latitude = latitude; self.longitude = longitude; self.hasGPS = hasGPS
        self.gpsFromTimeline = gpsFromTimeline; self.isFlagged = isFlagged
        self.rotationQuarterTurns = rotationQuarterTurns; self.aspectRatio = aspectRatio
        self.panelOrder = panelOrder; self.sortOrder = sortOrder; self.statusRaw = statusRaw
        self.imageSourceRaw = imageSourceRaw; self.imageURL = imageURL; self.googlePlaceId = googlePlaceId
        self.googleMapsURL = googleMapsURL; self.sourceURL = sourceURL; self.originalFilename = originalFilename
        self.photoFiles = photoFiles; self.thumbnailFiles = thumbnailFiles; self.dateTaken = dateTaken
        self.createdAt = createdAt; self.deletedAt = deletedAt
    }

    init(cursor c: SqlCursor) throws {
        id = try c.getString(name: "id")
        listId = try c.getStringOptional(name: "list_id")
        owningProjectId = try c.getStringOptional(name: "owning_project_id")
        name = (try c.getStringOptional(name: "name")) ?? ""
        notes = (try c.getStringOptional(name: "notes")) ?? ""
        latitude = (try c.getDoubleOptional(name: "latitude")) ?? 0
        longitude = (try c.getDoubleOptional(name: "longitude")) ?? 0
        hasGPS = (try c.getBooleanOptional(name: "has_gps")) ?? true
        gpsFromTimeline = (try c.getBooleanOptional(name: "gps_from_timeline")) ?? false
        isFlagged = (try c.getBooleanOptional(name: "is_flagged")) ?? false
        rotationQuarterTurns = Int(try c.getInt64(name: "rotation_quarter_turns"))
        aspectRatio = (try c.getDoubleOptional(name: "aspect_ratio")) ?? 0
        panelOrder = Int(try c.getInt64(name: "panel_order"))
        sortOrder = Int(try c.getInt64(name: "sort_order"))
        statusRaw = (try c.getStringOptional(name: "status_raw")) ?? ""
        imageSourceRaw = try c.getStringOptional(name: "image_source_raw")
        imageURL = try c.getStringOptional(name: "image_url")
        googlePlaceId = try c.getStringOptional(name: "google_place_id")
        googleMapsURL = try c.getStringOptional(name: "google_maps_url")
        sourceURL = try c.getStringOptional(name: "source_url")
        originalFilename = try c.getStringOptional(name: "original_filename")
        photoFiles = parseStringArray(try c.getStringOptional(name: "photo_files"))
        thumbnailFiles = parseStringArray(try c.getStringOptional(name: "thumbnail_files"))
        dateTaken = parseDate(try c.getStringOptional(name: "date_taken"))
        createdAt = parseDate(try c.getStringOptional(name: "created_at")) ?? Date()
        deletedAt = parseDate(try c.getStringOptional(name: "deleted_at"))
    }
}

struct ScriptRecord: Identifiable, Hashable {
    var id: String
    var projectId: String?
    var name: String
    var rawText: String
    var sortOrder: Int
    var importedAt: Date
    var updatedAt: Date

    init(cursor c: SqlCursor) throws {
        id = try c.getString(name: "id")
        projectId = try c.getStringOptional(name: "project_id")
        name = (try c.getStringOptional(name: "name")) ?? ""
        rawText = (try c.getStringOptional(name: "raw_text")) ?? ""
        sortOrder = Int(try c.getInt64(name: "sort_order"))
        importedAt = parseDate(try c.getStringOptional(name: "imported_at")) ?? Date()
        updatedAt = parseDate(try c.getStringOptional(name: "updated_at")) ?? Date()
    }
}

struct HighlightRecord: Identifiable, Hashable {
    var id: String
    var scriptId: String?
    var listId: String?
    var rangeStart: Int
    var rangeLength: Int
    var excerpt: String
    var contextBefore: String
    var contextAfter: String
    var sceneHeading: String?
    var createdAt: Date

    init(cursor c: SqlCursor) throws {
        id = try c.getString(name: "id")
        scriptId = try c.getStringOptional(name: "script_id")
        listId = try c.getStringOptional(name: "list_id")
        rangeStart = Int(try c.getInt64(name: "range_start"))
        rangeLength = Int(try c.getInt64(name: "range_length"))
        excerpt = (try c.getStringOptional(name: "excerpt")) ?? ""
        contextBefore = (try c.getStringOptional(name: "context_before")) ?? ""
        contextAfter = (try c.getStringOptional(name: "context_after")) ?? ""
        sceneHeading = try c.getStringOptional(name: "scene_heading")
        createdAt = parseDate(try c.getStringOptional(name: "created_at")) ?? Date()
    }
}
