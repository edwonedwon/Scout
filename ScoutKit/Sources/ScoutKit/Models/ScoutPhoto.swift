import Foundation
import CoreLocation

/// A photo imported from a scouting trip, with optional GPS data.
public struct ScoutPhoto: Identifiable, Codable {
    public let id: UUID
    public var localPath: String
    public var takenAt: Date?
    public var coordinate: Coordinate?
    public var inferredCoordinate: Coordinate?
    public var locationID: UUID?
    public var groupID: UUID?
    public var notes: String

    public struct Coordinate: Codable, Hashable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }

        public var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    public var resolvedCoordinate: Coordinate? {
        coordinate ?? inferredCoordinate
    }

    public init(
        id: UUID = UUID(),
        localPath: String,
        takenAt: Date? = nil,
        coordinate: Coordinate? = nil,
        inferredCoordinate: Coordinate? = nil,
        locationID: UUID? = nil,
        groupID: UUID? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.localPath = localPath
        self.takenAt = takenAt
        self.coordinate = coordinate
        self.inferredCoordinate = inferredCoordinate
        self.locationID = locationID
        self.groupID = groupID
        self.notes = notes
    }
}
