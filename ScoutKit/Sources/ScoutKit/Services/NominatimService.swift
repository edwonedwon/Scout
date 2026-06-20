import Foundation
import CoreLocation

public final class NominatimService {
    public static let shared = NominatimService()
    private init() {}

    private let base = "https://nominatim.openstreetmap.org/search"

    public struct BoundaryResult {
        public let name: String
        public let polygon: [CLLocationCoordinate2D]
        public let bbox: (minLat: Double, maxLat: Double, minLng: Double, maxLng: Double)
    }

    public func search(_ query: String) async throws -> BoundaryResult {
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            .init(name: "q",               value: query),
            .init(name: "polygon_geojson", value: "1"),
            .init(name: "format",          value: "json"),
            .init(name: "limit",           value: "5"),
        ]
        guard let url = comps.url else { throw NominatimError.badURL }

        var request = URLRequest(url: url)
        // Nominatim requires a meaningful User-Agent
        request.setValue("ScoutApp/1.0 (film location scouting)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await URLSession.shared.data(for: request)
        let results = try JSONDecoder().decode([NominatimResult].self, from: data)

        // Prefer results that have a polygon (not just a point)
        guard let match = results.first(where: { $0.geojson?.hasPolygon == true }) ?? results.first
        else { throw NominatimError.notFound(query) }

        guard let geojson = match.geojson, let polygon = geojson.largestRing
        else { throw NominatimError.noPolygon(match.displayName) }

        let lats = polygon.map(\.latitude)
        let lngs = polygon.map(\.longitude)
        return BoundaryResult(
            name: match.name,
            polygon: polygon,
            bbox: (lats.min()!, lats.max()!, lngs.min()!, lngs.max()!)
        )
    }

    // MARK: - Decoding

    private struct NominatimResult: Decodable {
        let displayName: String
        let geojson: GeoJSON?

        var name: String {
            // "California, United States" → "California"
            displayName.components(separatedBy: ", ").first ?? displayName
        }

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case geojson
        }
    }

    private struct GeoJSON: Decodable {
        let type: String
        let coordinates: CoordinateTree

        var hasPolygon: Bool { type == "Polygon" || type == "MultiPolygon" }

        // Returns the largest ring (most coordinate points) from Polygon or MultiPolygon
        var largestRing: [CLLocationCoordinate2D]? {
            let rings: [[CLLocationCoordinate2D]]
            switch type {
            case "Polygon":
                rings = coordinates.asRings()
            case "MultiPolygon":
                rings = coordinates.asMultiPolygonRings()
            default:
                return nil
            }
            return rings.max(by: { $0.count < $1.count })
        }

        enum CodingKeys: String, CodingKey { case type, coordinates }
    }

    // Flexible decoder for GeoJSON coordinate trees (array of array of array of [Double])
    private enum CoordinateTree: Decodable {
        case point([Double])
        case ring([[Double]])
        case polygon([[[Double]]])
        case multiPolygon([[[[Double]]]])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode([Double].self)         { self = .point(v); return }
            if let v = try? c.decode([[Double]].self)        { self = .ring(v); return }
            if let v = try? c.decode([[[Double]]].self)      { self = .polygon(v); return }
            if let v = try? c.decode([[[[Double]]]].self)    { self = .multiPolygon(v); return }
            self = .point([])
        }

        func asRings() -> [[CLLocationCoordinate2D]] {
            if case .polygon(let rings) = self { return rings.map(Self.toCoords) }
            return []
        }

        func asMultiPolygonRings() -> [[CLLocationCoordinate2D]] {
            if case .multiPolygon(let polys) = self { return polys.flatMap { $0.map(Self.toCoords) } }
            return []
        }

        private static func toCoords(_ pairs: [[Double]]) -> [CLLocationCoordinate2D] {
            // GeoJSON is [longitude, latitude]
            pairs.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
            }
        }
    }

    public enum NominatimError: LocalizedError {
        case badURL
        case notFound(String)
        case noPolygon(String)

        public var errorDescription: String? {
            switch self {
            case .badURL:             return "Invalid search URL."
            case .notFound(let q):    return "\u{201C}\(q)\u{201D} not found."
            case .noPolygon(let n):   return "No boundary available for \u{201C}\(n)\u{201D}."
            }
        }
    }
}
