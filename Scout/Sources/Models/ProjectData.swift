import Foundation
import SwiftData
import CoreLocation
import ScoutKit

// MARK: - Project

@Model
final class ProjectData {
    var name: String
    var notes: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var lists: [LocationListData] = []
    /// Photos imported directly into this project (not inside any list).
    @Relationship(deleteRule: .cascade, inverse: \PinnedLocationData.owningProject)
    var importedPhotos: [PinnedLocationData] = []

    init(name: String, notes: String = "") {
        self.name = name
        self.notes = notes
        self.createdAt = Date()
    }
}

// MARK: - Location list

@Model
final class LocationListData {
    var name: String
    var colorHex: String
    var createdAt: Date
    var sortOrder: Int = 0
    @Relationship(deleteRule: .cascade) var pins: [PinnedLocationData] = []
    var project: ProjectData?

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
    var name: String
    var notes: String
    var latitude: Double
    var longitude: Double
    var statusRaw: String
    var createdAt: Date
    var uuid: UUID = UUID()
    var sortOrder: Int = 0
    var imageURL: String? = nil
    var googlePlaceId: String? = nil
    // Original source, captured so photos can always be (re)fetched and saved offline.
    var sourceURLString: String? = nil
    var googleMapsURLString: String? = nil
    var imageSourceRaw: String? = nil
    // Filenames (in PinPhotoStore.directory) of photos downloaded for offline display.
    var photoFiles: [String] = []
    // Whether this pin has a real GPS coordinate. False for photos imported without EXIF GPS.
    // GPS-less pins appear in the list sidebar but not on the map.
    var hasGPS: Bool = true
    // Capture time from EXIF — reserved for a future Google Timeline sync feature that
    // will derive coordinates for GPS-less imported photos from Timeline movement data.
    var dateTaken: Date? = nil
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

    func asScoutLocation() -> ScoutLocation {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .googleMaps
        let images: [ScoutImage]
        if !photoFiles.isEmpty {
            // Offline: serve the downloaded files as file:// URLs through the usual loader.
            images = photoFiles.map { ScoutImage(url: PinPhotoStore.fileURL($0), source: source) }
        } else if let imageURL, let url = URL(string: imageURL) {
            images = [ScoutImage(url: url, source: source)]
        } else {
            images = []
        }
        return ScoutLocation(
            id: uuid,   // stable id so map selection/popover and annotation diffing work
            name: name,
            description: notes,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            sourceURL: sourceURLString.flatMap { URL(string: $0) },
            images: images,
            googleMapsURL: googleMapsURLString.flatMap { URL(string: $0) },
            googlePlaceId: googlePlaceId,
            status: LocationStatus(rawValue: statusRaw) ?? .scouted
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
