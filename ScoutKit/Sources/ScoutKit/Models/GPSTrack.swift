import Foundation
import CoreLocation

/// A GPS track recorded during a scouting trip, used to align un-geotagged photos.
public struct GPSTrack: Identifiable, Codable {
    public let id: UUID
    public var name: String
    public var points: [TrackPoint]
    public var source: TrackSource
    public var importedAt: Date

    public enum TrackSource: String, Codable {
        case googleTimeline = "Google Timeline"
        case liveRecording = "Live Recording"
        case gpxFile = "GPX File"
        case kmlFile = "KML File"
    }

    public struct TrackPoint: Codable {
        public var latitude: Double
        public var longitude: Double
        public var altitude: Double?
        public var timestamp: Date

        public var clCoordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        public init(latitude: Double, longitude: Double, altitude: Double? = nil, timestamp: Date) {
            self.latitude = latitude
            self.longitude = longitude
            self.altitude = altitude
            self.timestamp = timestamp
        }
    }

    public init(id: UUID = UUID(), name: String, points: [TrackPoint], source: TrackSource, importedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.points = points
        self.source = source
        self.importedAt = importedAt
    }

    /// Returns the interpolated coordinate at the given timestamp, or nil if out of range.
    public func interpolatedCoordinate(at date: Date) -> TrackPoint? {
        guard points.count >= 2 else { return points.first }
        let sorted = points.sorted { $0.timestamp < $1.timestamp }
        guard date >= sorted.first!.timestamp, date <= sorted.last!.timestamp else { return nil }

        for i in 0..<(sorted.count - 1) {
            let a = sorted[i]
            let b = sorted[i + 1]
            if date >= a.timestamp && date <= b.timestamp {
                let total = b.timestamp.timeIntervalSince(a.timestamp)
                let elapsed = date.timeIntervalSince(a.timestamp)
                let t = total > 0 ? elapsed / total : 0
                return TrackPoint(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t,
                    altitude: (a.altitude.map { av in b.altitude.map { bv in av + (bv - av) * t } ?? av }),
                    timestamp: date
                )
            }
        }
        return nil
    }
}
