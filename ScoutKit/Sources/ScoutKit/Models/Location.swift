import Foundation
import CoreLocation

public struct ScoutLocation: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var description: String
    public var coordinate: CLLocationCoordinate2D
    public var groupID: UUID?
    public var sourceURL: URL?
    public var images: [ScoutImage]
    public var googleMapsURL: URL?
    public var googlePlaceId: String?
    public var notes: String
    public var status: LocationStatus
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        coordinate: CLLocationCoordinate2D,
        groupID: UUID? = nil,
        sourceURL: URL? = nil,
        images: [ScoutImage] = [],
        googleMapsURL: URL? = nil,
        googlePlaceId: String? = nil,
        notes: String = "",
        status: LocationStatus = .scouted,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.coordinate = coordinate
        self.groupID = groupID
        self.sourceURL = sourceURL
        self.images = images
        self.googleMapsURL = googleMapsURL
        self.googlePlaceId = googlePlaceId
        self.notes = notes
        self.status = status
        self.createdAt = createdAt
    }
}

public enum LocationStatus: String, Codable, CaseIterable {
    case scouted = "Scouted"
    case shortlisted = "Shortlisted"
    case approved = "Approved"
    case rejected = "Rejected"
}

public struct ScoutImage: Identifiable, Codable, Hashable {
    public let id: UUID
    public var url: URL?
    public var localPath: String?
    public var caption: String
    public var source: ImageSource
    public var dateTaken: Date?

    public enum ImageSource: String, Codable {
        case googleMaps, streetView, instagram, youtube, imported, scouting
    }

    public init(id: UUID = UUID(), url: URL? = nil, localPath: String? = nil, caption: String = "", source: ImageSource, dateTaken: Date? = nil) {
        self.id = id
        self.url = url
        self.localPath = localPath
        self.caption = caption
        self.source = source
        self.dateTaken = dateTaken
    }
}

// CLLocationCoordinate2D doesn't conform to Codable by default
extension CLLocationCoordinate2D: @retroactive Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let lat = try container.decode(Double.self)
        let lng = try container.decode(Double.self)
        self.init(latitude: lat, longitude: lng)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(latitude)
        try container.encode(longitude)
    }
}

extension CLLocationCoordinate2D: @retroactive Hashable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
}
