import Foundation
import CoreLocation
import ScoutKit

/// Manages a freehand-drawn polygon that constrains all searches.
/// When polygon is nil, searches fall back to the current map view bounds.
@MainActor
final class SearchAreaManager: ObservableObject {
    static let shared = SearchAreaManager()
    private init() {}

    @Published var polygon: [CLLocationCoordinate2D]? = nil
    @Published var isDrawing = false

    var isActive: Bool { polygon != nil }

    func setPolygon(_ coords: [CLLocationCoordinate2D]) {
        guard coords.count >= 3 else { return }
        polygon = simplify(coords, tolerance: 0.00005)
        isDrawing = false
    }

    func clear() {
        polygon = nil
        isDrawing = false
    }

    /// Bounding box of the polygon for passing to APIs that accept a rect region.
    var mapRegion: GooglePlacesService.MapRegion? {
        guard let polygon else { return nil }
        let lats = polygon.map(\.latitude)
        let lngs = polygon.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return nil }
        return .init(
            centerLat: (minLat + maxLat) / 2,
            centerLng: (minLng + maxLng) / 2,
            latDelta: maxLat - minLat,
            lngDelta: maxLng - minLng
        )
    }

    /// Ray-casting point-in-polygon test. Returns true when no polygon is set (no constraint).
    func contains(_ coord: CLLocationCoordinate2D) -> Bool {
        guard let polygon, polygon.count >= 3 else { return true }
        let x = coord.longitude, y = coord.latitude
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    // Ramer-Douglas-Peucker to reduce point count before storing.
    private func simplify(_ points: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard points.count > 2 else { return points }
        var maxDist = 0.0
        var maxIndex = 0
        let last = points.count - 1
        for i in 1..<last {
            let d = perpendicularDistance(points[i], from: points[0], to: points[last])
            if d > maxDist { maxDist = d; maxIndex = i }
        }
        if maxDist > tolerance {
            let left  = simplify(Array(points[0...maxIndex]), tolerance: tolerance)
            let right = simplify(Array(points[maxIndex...last]), tolerance: tolerance)
            return left.dropLast() + right
        }
        return [points[0], points[last]]
    }

    private func perpendicularDistance(
        _ p: CLLocationCoordinate2D,
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let dx = b.longitude - a.longitude
        let dy = b.latitude  - a.latitude
        let len2 = dx*dx + dy*dy
        if len2 == 0 { return hypot(p.longitude - a.longitude, p.latitude - a.latitude) }
        let t = ((p.longitude - a.longitude)*dx + (p.latitude - a.latitude)*dy) / len2
        let projX = a.longitude + t*dx
        let projY = a.latitude  + t*dy
        return hypot(p.longitude - projX, p.latitude - projY)
    }
}
