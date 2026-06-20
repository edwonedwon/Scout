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
    @Relationship(inverse: \LocationListData.pins) var list: LocationListData?

    init(from location: ScoutLocation, sortOrder: Int = 0) {
        self.name = location.name
        self.notes = location.description
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.statusRaw = LocationStatus.scouted.rawValue
        self.createdAt = Date()
        self.sortOrder = sortOrder
        self.imageURL = location.images.first?.url?.absoluteString
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func asScoutLocation() -> ScoutLocation {
        let images: [ScoutImage] = imageURL.flatMap { URL(string: $0) }.map {
            [ScoutImage(url: $0, source: .googleMaps)]
        } ?? []
        return ScoutLocation(
            name: name,
            description: notes,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            images: images,
            status: LocationStatus(rawValue: statusRaw) ?? .scouted
        )
    }
}
