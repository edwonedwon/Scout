import Foundation
import SwiftData
import CoreLocation
import ScoutKit

// MARK: - Project

@Model
final class ProjectData {
    // Defaults on every non-optional attribute: CloudKit requires it (records can omit fields).
    // Adding a default doesn't change the stored type, so it's not a store migration.
    var name: String = ""
    var notes: String = ""
    var createdAt: Date = Date()
    var uuid: UUID = UUID()
    /// Sidebar order of the virtual "Uncategorized" row, in the same namespace as each
    /// top-level list's panelOrder. Lets Uncategorized be dragged among the lists.
    var uncategorizedPanelOrder: Int = 0
    @Relationship(deleteRule: .cascade, inverse: \LocationListData.project) var lists: [LocationListData] = []
    /// Photos imported directly into this project (not inside any list).
    @Relationship(deleteRule: .cascade, inverse: \PinnedLocationData.owningProject)
    var importedPhotos: [PinnedLocationData] = []
    /// Imported `.fountain` scripts (full text copied in, not referenced) — synced with the rest.
    @Relationship(deleteRule: .cascade, inverse: \ScriptData.project) var scripts: [ScriptData] = []

    init(name: String, notes: String = "") {
        self.name = name
        self.notes = notes
        self.createdAt = Date()
    }
}

// MARK: - Script

@Model
final class ScriptData {
    /// Display name (the imported filename without extension).
    var name: String = ""
    /// Full `.fountain` source text, copied into the store so it syncs (files are small).
    var rawText: String = ""
    var uuid: UUID = UUID()
    var importedAt: Date = Date()
    /// Bumped whenever a newer version is imported over this script.
    var updatedAt: Date = Date()
    /// Order within the sidebar "Scripts" section.
    var sortOrder: Int = 0
    var project: ProjectData?

    @Relationship(deleteRule: .cascade, inverse: \ScriptHighlight.script) var highlights: [ScriptHighlight] = []

    init(name: String, rawText: String, sortOrder: Int = 0) {
        self.name = name
        self.rawText = rawText
        self.importedAt = Date()
        self.updatedAt = Date()
        self.sortOrder = sortOrder
    }
}

// MARK: - Script highlight (a range of script linked to a list)

@Model
final class ScriptHighlight {
    var uuid: UUID = UUID()
    /// Character offset + length into the owning script's `rawText`.
    var rangeStart: Int = 0
    var rangeLength: Int = 0
    /// The highlighted text itself — the durable anchor used to re-locate the highlight when a
    /// newer version of the script is imported.
    var excerpt: String = ""
    /// Short surrounding text, to disambiguate when the excerpt appears more than once.
    var contextBefore: String = ""
    var contextAfter: String = ""
    /// Nearest preceding scene heading, for display and matching.
    var sceneHeading: String?
    var createdAt: Date = Date()
    var script: ScriptData?
    /// The list this script section is assigned to (the location for this scene/part).
    var list: LocationListData?

    init(rangeStart: Int, rangeLength: Int, excerpt: String,
         contextBefore: String = "", contextAfter: String = "", sceneHeading: String? = nil) {
        self.rangeStart = rangeStart
        self.rangeLength = rangeLength
        self.excerpt = excerpt
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.sceneHeading = sceneHeading
        self.createdAt = Date()
    }
}

// MARK: - Location list

@Model
final class LocationListData {
    var name: String = ""
    var colorHex: String = LocationListData.palette[0]
    var createdAt: Date = Date()
    var uuid: UUID = UUID()
    var sortOrder: Int = 0
    /// Order within the project panel sidebar (shared namespace with importedPhotos).
    var panelOrder: Int = 0
    /// Optional screenplay scene type for this list — "INT", "EXT", or "INT/EXT". nil = none.
    /// Shown as a small grey label on the list row; pickable via a menu.
    var sceneType: String? = nil
    /// When set, this list is in the Trash (soft-deleted): hidden from the sidebar, map, and
    /// grid, restorable via "Put Back", and auto-purged after 30 days — same rule as photos.
    var deletedAt: Date? = nil
    @Relationship(deleteRule: .cascade) var pins: [PinnedLocationData] = []
    var project: ProjectData?
    /// Script sections (scenes / parts of scenes) assigned to this list. Cascaded: a scene link
    /// only exists to tie a script range to THIS list, so deleting the list removes the link
    /// (it never deletes the script text itself — only the ScriptHighlight join object). A nullify
    /// rule here left orphaned highlights that still painted a "ghost" tint in the script.
    @Relationship(deleteRule: .cascade, inverse: \ScriptHighlight.list) var sceneLinks: [ScriptHighlight] = []

    // Self-referential nesting: a list may contain child lists, to any depth.
    var parentList: LocationListData?
    @Relationship(deleteRule: .cascade, inverse: \LocationListData.parentList)
    var childLists: [LocationListData] = []

    init(name: String, colorHex: String = LocationListData.palette[0]) {
        self.name = name
        self.colorHex = colorHex
        self.createdAt = Date()
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

@Model
final class PinnedLocationData {
    var name: String = ""
    var notes: String = ""
    var latitude: Double = 0
    var longitude: Double = 0
    var statusRaw: String = ""
    var createdAt: Date = Date()
    var uuid: UUID = UUID()
    var sortOrder: Int = 0
    /// Order within the project panel sidebar (shared namespace with lists).
    var panelOrder: Int = 0
    var imageURL: String? = nil
    var googlePlaceId: String? = nil
    // Original source, captured so photos can always be (re)fetched and saved offline.
    var sourceURLString: String? = nil
    var googleMapsURLString: String? = nil
    var imageSourceRaw: String? = nil
    // Compressed full-res versions (2048px JPEG) stored in PinPhotoStore.directory.
    // For imported photos these are derived from the original; for Google places they
    // are the downloaded remote images. Used in the carousel when the original is absent.
    var photoFiles: [String] = []
    // Small thumbnail versions (300px JPEG) stored in PinPhotoStore.directory.
    // Used everywhere except the full-screen carousel (sidebar, map, photo grid).
    var thumbnailFiles: [String] = []
    // Absolute path to the original file on disk (only set for imported photos).
    // Not copied into the app container — read directly when the file is available.
    // The carousel prefers this over photoFiles when the path resolves.
    var originalFilePath: String? = nil
    // Whether this pin has a real GPS coordinate. False for photos imported without EXIF GPS.
    // GPS-less pins appear in the list sidebar but not on the map.
    var hasGPS: Bool = true
    // True when this pin's GPS came from a Google Timeline backfill (not the original file's
    // EXIF). Re-running the timeline import may overwrite these, but never pins whose GPS
    // came from the original photo file (gpsFromTimeline == false && hasGPS == true).
    var gpsFromTimeline: Bool = false
    // Capture time from EXIF — reserved for a future Google Timeline sync feature that
    // will derive coordinates for GPS-less imported photos from Timeline movement data.
    var dateTaken: Date? = nil
    /// When set, this pin is in the Trash. It's hidden from all normal views and lives only
    /// in the Trash section until restored, manually emptied, or auto-purged after 30 days.
    var deletedAt: Date? = nil
    /// Counter-clockwise 90° rotation steps applied when displaying this photo (0–3).
    /// Set by the "R" rotate command; baked into every ScoutImage this pin produces.
    var rotationQuarterTurns: Int = 0
    /// Unrotated pixel aspect ratio (width / height) of the photo; 0 when not yet measured.
    /// Captured at import (and backfilled for older pins) so the photo grid can size each
    /// cell to its final height immediately — no reflow when the thumbnail finishes loading.
    var aspectRatio: Double = 0
    /// Marked as a confirmed/favorite filming location ("flagged"). Sorts to the top of its
    /// list and shows a marker in the sidebar, grid, and on the map.
    var isFlagged: Bool = false
    @Relationship(inverse: \LocationListData.pins) var list: LocationListData?
    /// Set when this pin was imported directly into a project (not inside a list).
    var owningProject: ProjectData? = nil

    init(from location: ScoutLocation, sortOrder: Int = 0) {
        self.name = location.name
        self.notes = location.description
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.statusRaw = LocationStatus.scouted.rawValue
        self.createdAt = Date()
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
            // isReadableFile checks both existence AND sandbox read permission,
            // unlike fileExists which only stats the file (and returns true for
            // sandboxed-but-unreadable paths after user-selected access expires).
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

// MARK: - Preview sample data

#if DEBUG
@MainActor
enum PreviewData {
    /// In-memory store with one project, one list, and a couple of saved pins —
    /// for SwiftData-backed previews (ProjectsPanel, ContentView).
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: ProjectData.self, LocationListData.self, PinnedLocationData.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let project = ProjectData(name: "Tokyo Shoot")
        ctx.insert(project)
        let list = LocationListData(name: "Day 1 — Shibuya", colorHex: LocationListData.palette[1])
        ctx.insert(list)
        list.project = project
        for (i, loc) in [ScoutLocation.preview, .previewNoPhotos].enumerated() {
            let pin = PinnedLocationData(from: loc, sortOrder: i)
            ctx.insert(pin)
            pin.list = list
        }
        return container
    }()
}
#endif
