import Foundation
import CoreLocation

public final class JapanBoundaryService {
    public static let shared = JapanBoundaryService()
    private init() {}

    private let base = "https://overpass-api.de/api/interpreter"

    public struct BoundaryData: Identifiable, Sendable {
        public let id: Int
        public let name: String
        public let nameEn: String?
        public let adminLevel: Int
        public let rings: [[CLLocationCoordinate2D]]
        public let center: CLLocationCoordinate2D
    }

    // MARK: - Cache

    private var prefectureCache: [BoundaryData]? = nil
    private var municipalityCache: [String: [BoundaryData]] = [:]  // bbox key → data

    // MARK: - Public API

    public func clearPrefectureCache() { prefectureCache = nil }

    public func fetchPrefectures() async throws -> [BoundaryData] {
        if let cached = prefectureCache { return cached }
        // ISO3166-2 "JP-*" is the most reliable way to target exactly the 47 Japanese prefectures
        let query = """
        [out:json][timeout:90];
        (
          relation["admin_level"="4"]["boundary"="administrative"]["ISO3166-2"~"^JP-"];
        );
        out geom;
        """
        let result = try await runQuery(query)
        let simplified = result.map { simplify($0, tolerance: 0.002) }
        prefectureCache = simplified
        return simplified
    }

    public func fetchMunicipalities(in region: BoundingBox) async throws -> [BoundaryData] {
        let key = region.cacheKey
        if let cached = municipalityCache[key] { return cached }
        let query = """
        [out:json][timeout:45];
        (
          relation["admin_level"="7"]["boundary"="administrative"]["name"](\(region.overpassFormat));
          relation["admin_level"="8"]["boundary"="administrative"]["name"](\(region.overpassFormat));
        );
        out geom;
        """
        let result = try await runQuery(query)
        let simplified = result.map { simplify($0, tolerance: 0.0005) }
        municipalityCache[key] = simplified
        return simplified
    }

    public struct BoundingBox {
        public let south: Double
        public let west: Double
        public let north: Double
        public let east: Double
        public init(south: Double, west: Double, north: Double, east: Double) {
            self.south = south; self.west = west; self.north = north; self.east = east
        }
        var overpassFormat: String { "\(south),\(west),\(north),\(east)" }
        var cacheKey: String {
            // Round to ~50km grid cells
            let s = (south * 5).rounded() / 5
            let w = (west * 5).rounded() / 5
            return "\(s),\(w)"
        }
    }

    // MARK: - Overpass fetch + parse

    private func runQuery(_ query: String) async throws -> [BoundaryData] {
        var req = URLRequest(url: URL(string: base)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        return response.elements.compactMap(parseBoundary)
    }

    private func parseBoundary(_ element: OverpassElement) -> BoundaryData? {
        guard element.type == "relation",
              let name = element.tags?["name"] else { return nil }
        let nameEn = element.tags?["name:en"]
        let adminLevel = Int(element.tags?["admin_level"] ?? "0") ?? 0

        let outerWays = (element.members ?? [])
            .filter { $0.role == "outer" }
            .compactMap { $0.geometry?.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
            .filter { $0.count >= 2 }

        let rings = assembleRings(from: outerWays)
        guard !rings.isEmpty else { return nil }

        let center = computeCenter(rings.first!)
        return BoundaryData(id: element.id, name: name, nameEn: nameEn,
                            adminLevel: adminLevel, rings: rings, center: center)
    }

    // MARK: - Ring assembly (joins adjacent OSM ways into closed polygon rings)

    private func assembleRings(from ways: [[CLLocationCoordinate2D]]) -> [[CLLocationCoordinate2D]] {
        var remaining = ways
        var rings: [[CLLocationCoordinate2D]] = []
        let eps = 1e-5

        while !remaining.isEmpty {
            var ring = remaining.removeFirst()
            var progress = true
            while progress {
                progress = false
                var i = 0
                while i < remaining.count {
                    let way = remaining[i]
                    let tail = ring.last!
                    let head = way.first!
                    let foot = way.last!
                    if abs(tail.latitude - head.latitude) < eps && abs(tail.longitude - head.longitude) < eps {
                        ring.append(contentsOf: way.dropFirst())
                        remaining.remove(at: i)
                        progress = true
                    } else if abs(tail.latitude - foot.latitude) < eps && abs(tail.longitude - foot.longitude) < eps {
                        ring.append(contentsOf: way.reversed().dropFirst())
                        remaining.remove(at: i)
                        progress = true
                    } else { i += 1 }
                }
            }
            if ring.count >= 3 { rings.append(ring) }
        }
        return rings
    }

    // MARK: - Simplification (Ramer-Douglas-Peucker)

    private func simplify(_ boundary: BoundaryData, tolerance: Double) -> BoundaryData {
        let simplified = boundary.rings.map { rdp($0, tolerance: tolerance) }
        return BoundaryData(id: boundary.id, name: boundary.name, nameEn: boundary.nameEn,
                            adminLevel: boundary.adminLevel, rings: simplified, center: boundary.center)
    }

    private func rdp(_ pts: [CLLocationCoordinate2D], tolerance: Double) -> [CLLocationCoordinate2D] {
        guard pts.count > 2 else { return pts }
        var maxDist = 0.0; var maxIdx = 0
        let last = pts.count - 1
        for i in 1..<last {
            let d = perpendicularDist(pts[i], from: pts[0], to: pts[last])
            if d > maxDist { maxDist = d; maxIdx = i }
        }
        if maxDist > tolerance {
            let l = rdp(Array(pts[0...maxIdx]), tolerance: tolerance)
            let r = rdp(Array(pts[maxIdx...last]), tolerance: tolerance)
            return l.dropLast() + r
        }
        return [pts[0], pts[last]]
    }

    private func perpendicularDist(_ p: CLLocationCoordinate2D, from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let dx = b.longitude - a.longitude; let dy = b.latitude - a.latitude
        let len2 = dx*dx + dy*dy
        if len2 == 0 { return hypot(p.longitude - a.longitude, p.latitude - a.latitude) }
        let t = ((p.longitude - a.longitude)*dx + (p.latitude - a.latitude)*dy) / len2
        return hypot(p.longitude - (a.longitude + t*dx), p.latitude - (a.latitude + t*dy))
    }

    private func computeCenter(_ ring: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D {
        let lat = ring.map(\.latitude).reduce(0, +) / Double(ring.count)
        let lon = ring.map(\.longitude).reduce(0, +) / Double(ring.count)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // MARK: - Overpass JSON types

    private struct OverpassResponse: Decodable {
        let elements: [OverpassElement]
    }
    private struct OverpassElement: Decodable {
        let type: String
        let id: Int
        let tags: [String: String]?
        let members: [OverpassMember]?
    }
    private struct OverpassMember: Decodable {
        let type: String
        let role: String
        let geometry: [OverpassNode]?
    }
    private struct OverpassNode: Decodable {
        let lat: Double
        let lon: Double
    }
}
