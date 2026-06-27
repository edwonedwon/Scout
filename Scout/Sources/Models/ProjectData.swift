import Foundation
import CoreData
import CoreLocation
import ScoutKit

// MARK: - Core Data + CloudKit model
//
// These NSManagedObject subclasses replace the former SwiftData `@Model` types as part of the
// CloudKit collaboration migration (docs/collaboration-plan.md, Path B). Class names and the
// public API surface are kept IDENTICAL to the old `@Model` types so view code barely changes:
//   • to-many relationships are exposed as `[T]` arrays (read-modify-write through KVC),
//   • `[String]` arrays are stored as CloudKit-safe JSON strings and wrapped as `[String]`,
//   • `uuid` is a non-optional wrapper over the optional stored `uuidRaw` (CloudKit needs the
//     stored attribute optional; UUID has no static default),
//   • convenience `init(context:...)` mirrors the old initializers — call sites pass the context
//     and the now-redundant `modelContext.insert(_:)` becomes a harmless no-op.
//
// Codegen for the .xcdatamodeld is Manual/None — these hand-written classes are the only
// definitions of each entity's class.

// MARK: - Small KVC helpers for to-many relationships

private extension NSManagedObject {
    /// Reads a to-many relationship as an (unordered) Swift array — matches SwiftData semantics
    /// (callers sort where order matters).
    func relationshipArray<T: NSManagedObject>(_ key: String) -> [T] {
        (value(forKey: key) as? NSSet)?.allObjects as? [T] ?? []
    }
    /// Replaces a to-many relationship from a Swift array. Read-modify-write of the array (e.g.
    /// `obj.children.append(x)`) routes through here; Core Data maintains the inverse.
    func setRelationshipArray<T: NSManagedObject>(_ key: String, _ newValue: [T]) {
        setValue(NSSet(array: newValue), forKey: key)
    }
}

private func decodeStringArray(_ s: String) -> [String] {
    guard let d = s.data(using: .utf8),
          let a = try? JSONDecoder().decode([String].self, from: d) else { return [] }
    return a
}
private func encodeStringArray(_ a: [String]) -> String {
    guard let d = try? JSONEncoder().encode(a),
          let s = String(data: d, encoding: .utf8) else { return "[]" }
    return s
}

// MARK: - Project

@objc(ProjectData)
final class ProjectData: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var notes: String
    @NSManaged var createdAt: Date
    @NSManaged private var uuidRaw: UUID?
    /// Sidebar order of the virtual "Uncategorized" row, in the same namespace as each
    /// top-level list's panelOrder. Lets Uncategorized be dragged among the lists.
    @NSManaged var uncategorizedPanelOrder: Int
    /// When set, this project is in the Trash — hidden from the sidebar and map until restored
    /// or permanently deleted after 30 days.
    @NSManaged var deletedAt: Date?

    var uuid: UUID {
        get { if let u = uuidRaw { return u }; let u = UUID(); uuidRaw = u; return u }
        set { uuidRaw = newValue }
    }

    var lists: [LocationListData] {
        get { relationshipArray("lists") }
        set { setRelationshipArray("lists", newValue) }
    }
    /// Photos imported directly into this project (not inside any list).
    var importedPhotos: [PinnedLocationData] {
        get { relationshipArray("importedPhotos") }
        set { setRelationshipArray("importedPhotos", newValue) }
    }
    /// Imported `.fountain` scripts (full text copied in, not referenced) — synced with the rest.
    var scripts: [ScriptData] {
        get { relationshipArray("scripts") }
        set { setRelationshipArray("scripts", newValue) }
    }

    // MARK: - Live (non-trashed) accessors
    //
    // The raw `lists` / `importedPhotos` relationships above ALSO contain soft-deleted
    // (trashed) objects — `deletedAt` is just a flag, the relationship link survives until
    // the 30-day purge. ANY user-facing read (counts, sidebar, grid, map, search, fit,
    // reveal) MUST go through these `live…` accessors so trashed items appear ONLY in the
    // Trash bin. Use the raw relationships solely for mutation, purge/trash, backup, and
    // by-UUID relink lookups.

    /// Lists in this project that are NOT in the Trash.
    var liveLists: [LocationListData] { lists.filter { $0.deletedAt == nil } }
    /// Loose (uncategorized) photos in this project that are NOT in the Trash.
    var livePhotos: [PinnedLocationData] { importedPhotos.filter { $0.deletedAt == nil } }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        createdAt = Date()
        uuidRaw = UUID()
    }

    convenience init(context: NSManagedObjectContext, name: String, notes: String = "") {
        self.init(context: context)
        try? context.obtainPermanentIDs(for: [self])
        self.name = name
        self.notes = notes
    }
}

// MARK: - Script

@objc(ScriptData)
final class ScriptData: NSManagedObject {
    /// Display name (the imported filename without extension).
    @NSManaged var name: String
    /// Full `.fountain` source text, copied into the store so it syncs (files are small).
    @NSManaged var rawText: String
    @NSManaged private var uuidRaw: UUID?
    @NSManaged var importedAt: Date
    /// Bumped whenever a newer version is imported over this script.
    @NSManaged var updatedAt: Date
    /// Order within the sidebar "Scripts" section.
    @NSManaged var sortOrder: Int
    @NSManaged var project: ProjectData?

    var uuid: UUID {
        get { if let u = uuidRaw { return u }; let u = UUID(); uuidRaw = u; return u }
        set { uuidRaw = newValue }
    }

    var highlights: [ScriptHighlight] {
        get { relationshipArray("highlights") }
        set { setRelationshipArray("highlights", newValue) }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        let now = Date()
        importedAt = now
        updatedAt = now
        uuidRaw = UUID()
    }

    convenience init(context: NSManagedObjectContext, name: String, rawText: String, sortOrder: Int = 0) {
        self.init(context: context)
        try? context.obtainPermanentIDs(for: [self])
        self.name = name
        self.rawText = rawText
        self.sortOrder = sortOrder
    }
}

// MARK: - Script highlight (a range of script linked to a list)

@objc(ScriptHighlight)
final class ScriptHighlight: NSManagedObject {
    @NSManaged private var uuidRaw: UUID?
    /// Character offset + length into the owning script's `rawText`.
    @NSManaged var rangeStart: Int
    @NSManaged var rangeLength: Int
    /// The highlighted text itself — the durable anchor used to re-locate the highlight when a
    /// newer version of the script is imported.
    @NSManaged var excerpt: String
    /// Short surrounding text, to disambiguate when the excerpt appears more than once.
    @NSManaged var contextBefore: String
    @NSManaged var contextAfter: String
    /// Nearest preceding scene heading, for display and matching.
    @NSManaged var sceneHeading: String?
    @NSManaged var createdAt: Date
    @NSManaged var script: ScriptData?
    /// The list this script section is assigned to (the location for this scene/part).
    @NSManaged var list: LocationListData?

    var uuid: UUID {
        get { if let u = uuidRaw { return u }; let u = UUID(); uuidRaw = u; return u }
        set { uuidRaw = newValue }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        createdAt = Date()
        uuidRaw = UUID()
    }

    convenience init(context: NSManagedObjectContext, rangeStart: Int, rangeLength: Int, excerpt: String,
                     contextBefore: String = "", contextAfter: String = "", sceneHeading: String? = nil) {
        self.init(context: context)
        try? context.obtainPermanentIDs(for: [self])
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.excerpt = excerpt
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.sceneHeading = sceneHeading
    }
}

// MARK: - Location list

@objc(LocationListData)
final class LocationListData: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var colorHex: String
    @NSManaged var createdAt: Date
    @NSManaged private var uuidRaw: UUID?
    @NSManaged var sortOrder: Int
    /// Order within the project panel sidebar (shared namespace with importedPhotos).
    @NSManaged var panelOrder: Int
    /// Optional screenplay scene type for this list — "INT", "EXT", or "INT/EXT". nil = none.
    @NSManaged var sceneType: String?
    /// When set, this list is in the Trash (soft-deleted): hidden from the sidebar, map, and
    /// grid, restorable via "Put Back", and auto-purged after 30 days — same rule as photos.
    @NSManaged var deletedAt: Date?
    @NSManaged var project: ProjectData?
    @NSManaged var parentList: LocationListData?

    var uuid: UUID {
        get { if let u = uuidRaw { return u }; let u = UUID(); uuidRaw = u; return u }
        set { uuidRaw = newValue }
    }

    var pins: [PinnedLocationData] {
        get { relationshipArray("pins") }
        set { setRelationshipArray("pins", newValue) }
    }
    /// Script sections (scenes / parts of scenes) assigned to this list. Deleting the list removes
    /// these join objects in code (never the script text itself).
    var sceneLinks: [ScriptHighlight] {
        get { relationshipArray("sceneLinks") }
        set { setRelationshipArray("sceneLinks", newValue) }
    }
    // Self-referential nesting: a list may contain child lists, to any depth.
    var childLists: [LocationListData] {
        get { relationshipArray("childLists") }
        set { setRelationshipArray("childLists", newValue) }
    }

    // MARK: - Live (non-trashed) accessors
    //
    // `pins` / `childLists` above include soft-deleted (trashed) members — `deletedAt` is a
    // flag, the relationship link survives until purge. Every user-facing read (counts,
    // display, search, map fit, reveal) MUST use these so trashed items show ONLY in the
    // Trash bin. Raw relationships are for mutation, trash/purge, backup, and relink lookups.

    /// Pins in this list that are NOT in the Trash.
    var livePins: [PinnedLocationData] { pins.filter { $0.deletedAt == nil } }
    /// Child lists (folders) that are NOT in the Trash.
    var liveChildLists: [LocationListData] { childLists.filter { $0.deletedAt == nil } }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        createdAt = Date()
        uuidRaw = UUID()
    }

    convenience init(context: NSManagedObjectContext, name: String, colorHex: String = LocationListData.palette[0]) {
        self.init(context: context)
        try? context.obtainPermanentIDs(for: [self])
        self.name = name
        self.colorHex = colorHex
    }

    static let palette = [
        "#FF6B35", // orange
        "#2196F3", // blue
        "#4CAF50", // green
        "#9C27B0", // purple
        "#E91E63", // pink
        "#00BCD4", // cyan
        "#FF5722", // deep orange
        "#FFEB3B", // yellow
    ]

    func nextColor(for project: ProjectData) -> String {
        let idx = project.lists.count % LocationListData.palette.count
        return LocationListData.palette[idx]
    }
}

// MARK: - Pinned location

@objc(PinnedLocationData)
final class PinnedLocationData: NSManagedObject {
    @NSManaged var name: String
    @NSManaged var notes: String
    @NSManaged var latitude: Double
    @NSManaged var longitude: Double
    @NSManaged var statusRaw: String
    @NSManaged var createdAt: Date
    @NSManaged private var uuidRaw: UUID?
    @NSManaged var sortOrder: Int
    /// Order within the project panel sidebar (shared namespace with lists).
    @NSManaged var panelOrder: Int
    @NSManaged var imageURL: String?
    @NSManaged var googlePlaceId: String?
    // Original source, captured so photos can always be (re)fetched and saved offline.
    @NSManaged var sourceURLString: String?
    @NSManaged var googleMapsURLString: String?
    @NSManaged var imageSourceRaw: String?
    // JSON-encoded backing store for the `[String]` file-name arrays (CloudKit-safe).
    @NSManaged private var photoFilesJSON: String
    @NSManaged private var thumbnailFilesJSON: String
    // Absolute path to the original file on disk (only set for imported photos). This is a
    // LOCAL convenience (used by the carousel for max quality on this Mac); it does not sync —
    // an absolute path is meaningless on another device.
    @NSManaged var originalFilePath: String?
    // The original file's name, e.g. "DSC02453.HIF". This is the SYNCED, device-independent
    // reference to the original — paired with dateTaken/lat/lng it lets any device re-locate the
    // original by re-scanning a chosen folder (see BackupService.relinkOriginals).
    @NSManaged var originalFilename: String?
    // Whether this pin has a real GPS coordinate. False for photos imported without EXIF GPS.
    @NSManaged var hasGPS: Bool
    // True when this pin's GPS came from a Google Timeline backfill (not the original file's EXIF).
    @NSManaged var gpsFromTimeline: Bool
    // Capture time from EXIF — reserved for a future Google Timeline sync feature.
    @NSManaged var dateTaken: Date?
    /// When set, this pin is in the Trash. Hidden from all normal views; auto-purged after 30 days.
    @NSManaged var deletedAt: Date?
    /// Counter-clockwise 90° rotation steps applied when displaying this photo (0–3).
    @NSManaged var rotationQuarterTurns: Int
    /// Unrotated pixel aspect ratio (width / height) of the photo; 0 when not yet measured.
    @NSManaged var aspectRatio: Double
    /// Marked as a confirmed/favorite filming location ("flagged").
    @NSManaged var isFlagged: Bool
    @NSManaged var list: LocationListData?
    /// Set when this pin was imported directly into a project (not inside a list).
    @NSManaged var owningProject: ProjectData?

    var uuid: UUID {
        get { if let u = uuidRaw { return u }; let u = UUID(); uuidRaw = u; return u }
        set { uuidRaw = newValue }
    }

    // Compressed full-res versions (2048px JPEG) stored in PinPhotoStore.directory.
    var photoFiles: [String] {
        get { decodeStringArray(photoFilesJSON) }
        set { photoFilesJSON = encodeStringArray(newValue) }
    }
    // Small thumbnail versions (300px JPEG) stored in PinPhotoStore.directory.
    var thumbnailFiles: [String] {
        get { decodeStringArray(thumbnailFilesJSON) }
        set { thumbnailFilesJSON = encodeStringArray(newValue) }
    }

    override func awakeFromInsert() {
        super.awakeFromInsert()
        createdAt = Date()
        uuidRaw = UUID()
    }

    convenience init(context: NSManagedObjectContext, from location: ScoutLocation, sortOrder: Int = 0) {
        self.init(context: context)
        try? context.obtainPermanentIDs(for: [self])
        self.name = location.name
        self.notes = location.description
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.statusRaw = LocationStatus.scouted.rawValue
        self.sortOrder = sortOrder
        self.imageURL = location.images.first?.url?.absoluteString
        self.googlePlaceId = location.googlePlaceId
        self.sourceURLString = location.sourceURL?.absoluteString
        self.googleMapsURLString = location.googleMapsURL?.absoluteString
        self.imageSourceRaw = location.images.first?.source.rawValue
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Images sized for thumbnails — sidebar rows, photo grid, map pins.
    /// Uses thumbnailFiles when available, falls back to photoFiles.
    var thumbnailImages: [ScoutImage] {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .imported
        let files = thumbnailFiles.isEmpty ? photoFiles : thumbnailFiles
        return files.map { ScoutImage(url: PinPhotoStore.fileURL($0), source: source, dateTaken: dateTaken, rotationQuarterTurns: rotationQuarterTurns, aspectRatio: aspectRatio) }
    }

    /// Images for the full-screen carousel.
    /// Prefers the original file on disk (if it still exists), then falls back to photoFiles.
    var fullResImages: [ScoutImage] {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .imported
        // Try the original file first.
        if let path = originalFilePath {
            let url = URL(fileURLWithPath: path)
            // isReadableFile checks both existence AND sandbox read permission.
            if FileManager.default.isReadableFile(atPath: path) {
                return [ScoutImage(url: url, source: source, dateTaken: dateTaken, rotationQuarterTurns: rotationQuarterTurns)]
            }
        }
        // Fall back to compressed full-res files.
        if !photoFiles.isEmpty {
            return photoFiles.map { ScoutImage(url: PinPhotoStore.fileURL($0), source: source, dateTaken: dateTaken, rotationQuarterTurns: rotationQuarterTurns) }
        }
        return []
    }

    func asScoutLocation() -> ScoutLocation {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .googleMaps
        let images: [ScoutImage]
        if !photoFiles.isEmpty || !thumbnailFiles.isEmpty {
            // Use thumbnails for all non-carousel display (grid, sidebar, map pins).
            images = thumbnailImages
        } else if let imageURL, let url = URL(string: imageURL) {
            images = [ScoutImage(url: url, source: source)]
        } else {
            images = []
        }
        return ScoutLocation(
            id: uuid,
            name: name,
            description: notes,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            sourceURL: sourceURLString.flatMap { URL(string: $0) },
            images: images,
            fullResImages: fullResImages,
            googleMapsURL: googleMapsURLString.flatMap { URL(string: $0) },
            googlePlaceId: googlePlaceId,
            status: LocationStatus(rawValue: statusRaw) ?? .scouted,
            isFlagged: isFlagged
        )
    }
}

// MARK: - SwiftData compatibility shims
//
// Keep the rest of the codebase compiling with minimal churn during the migration:
//   • `PersistentIdentifier` was SwiftData's stable object id; Core Data's equivalent is
//     `NSManagedObjectID`. New objects get permanent ids at creation (see the inits) so the id
//     is stable from insert, matching SwiftData semantics.
//   • `persistentModelID` mirrors SwiftData's accessor onto `objectID`.
typealias PersistentIdentifier = NSManagedObjectID

extension NSManagedObject {
    var persistentModelID: NSManagedObjectID { objectID }
}

// SwiftData `@Model` types were implicitly `Identifiable` (keyed by their persistent id), which
// plain `ForEach(models)` call sites rely on. Mirror that with `objectID` — stable from insert
// because every convenience initializer calls `obtainPermanentIDs`.
extension ProjectData: Identifiable { var id: NSManagedObjectID { objectID } }
extension ScriptData: Identifiable { var id: NSManagedObjectID { objectID } }
extension ScriptHighlight: Identifiable { var id: NSManagedObjectID { objectID } }
extension LocationListData: Identifiable { var id: NSManagedObjectID { objectID } }
extension PinnedLocationData: Identifiable { var id: NSManagedObjectID { objectID } }

/// Migration shim for SwiftData's `FetchDescriptor(T.self)` (always used here with no predicate/sort):
/// returns a Core Data fetch request for all rows of the entity, so existing
/// `context.fetch(FetchDescriptor(T.self))` call sites compile unchanged.
func FetchDescriptor<T: NSManagedObject>(_ type: T.Type = T.self) -> NSFetchRequest<T> {
    NSFetchRequest<T>(entityName: String(describing: T.self))
}
