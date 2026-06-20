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
    @Relationship(deleteRule: .cascade) var pins: [PinnedLocationData] = []
    var project: ProjectData?

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
    var list: LocationListData?

    init(from location: ScoutLocation) {
        self.name = location.name
        self.notes = location.description
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.statusRaw = LocationStatus.scouted.rawValue
        self.createdAt = Date()
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func asScoutLocation() -> ScoutLocation {
        ScoutLocation(
            name: name,
            description: notes,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            status: LocationStatus(rawValue: statusRaw) ?? .scouted
        )
    }
}
