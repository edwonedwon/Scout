import XCTest
@testable import ScoutKit

final class ScoutKitTests: XCTestCase {
    func testGPSTrackInterpolation() {
        let a = GPSTrack.TrackPoint(latitude: 35.0, longitude: 139.0, timestamp: Date(timeIntervalSince1970: 0))
        let b = GPSTrack.TrackPoint(latitude: 36.0, longitude: 140.0, timestamp: Date(timeIntervalSince1970: 100))
        let track = GPSTrack(name: "Test", points: [a, b], source: .gpxFile)

        let mid = track.interpolatedCoordinate(at: Date(timeIntervalSince1970: 50))
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid?.latitude ?? 0, 35.5, accuracy: 0.001)
        XCTAssertEqual(mid?.longitude ?? 0, 139.5, accuracy: 0.001)
    }

    func testGPSTrackOutOfRange() {
        let a = GPSTrack.TrackPoint(latitude: 35.0, longitude: 139.0, timestamp: Date(timeIntervalSince1970: 0))
        let b = GPSTrack.TrackPoint(latitude: 36.0, longitude: 140.0, timestamp: Date(timeIntervalSince1970: 100))
        let track = GPSTrack(name: "Test", points: [a, b], source: .gpxFile)

        let before = track.interpolatedCoordinate(at: Date(timeIntervalSince1970: -10))
        let after = track.interpolatedCoordinate(at: Date(timeIntervalSince1970: 200))
        XCTAssertNil(before)
        XCTAssertNil(after)
    }

    func testScoutPhotoResolvedCoordinate() {
        let gps = ScoutPhoto.Coordinate(latitude: 35.0, longitude: 139.0)
        let inferred = ScoutPhoto.Coordinate(latitude: 36.0, longitude: 140.0)

        let withGPS = ScoutPhoto(localPath: "test.jpg", coordinate: gps, inferredCoordinate: inferred)
        XCTAssertEqual(withGPS.resolvedCoordinate, gps)

        let withInferred = ScoutPhoto(localPath: "test.jpg", inferredCoordinate: inferred)
        XCTAssertEqual(withInferred.resolvedCoordinate, inferred)
    }
}
