import Foundation
import CoreLocation

public actor GooglePlacesService {
    public static let shared = GooglePlacesService()

    private let baseURL = URL(string: "https://places.googleapis.com/v1/places:searchText")!
    // Keep this to Places "Pro" SKU fields only. `rating`/`userRatingCount` are
    // "Enterprise" SKU fields (more expensive per request) and aren't used anywhere in
    // the app, so requesting them just inflated every Text Search bill.
    private let fieldMask = "places.id,places.displayName,places.location,places.formattedAddress,places.googleMapsUri,places.photos"

    private var apiKey: String? {
        KeychainService.load(forKey: KeychainService.googleMapsAPIKey)
    }

    // MARK: - Search result cache

    private struct CacheKey: Hashable {
        let query: String       // lowercased + trimmed
        let latBucket: Int      // center lat rounded to ~1 km (2 decimal places × 100)
        let lngBucket: Int
        let latSpan: Int        // region size bucket (rounded to 1 decimal place × 10)
        let lngSpan: Int

        init(query: String, region: MapRegion?) {
            self.query = query.lowercased().trimmingCharacters(in: .whitespaces)
            if let r = region {
                latBucket = Int((r.centerLat * 100).rounded())
                lngBucket = Int((r.centerLng * 100).rounded())
                latSpan   = Int((r.latDelta   * 10).rounded())
                lngSpan   = Int((r.lngDelta   * 10).rounded())
            } else {
                latBucket = 0; lngBucket = 0; latSpan = 0; lngSpan = 0
            }
        }

        /// Stable filename derived from all fields — same approach as photo cache.
        var diskFilename: String {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in "\(query)|\(latBucket)|\(lngBucket)|\(latSpan)|\(lngSpan)".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            return String(hash, radix: 16)
        }
    }

    private struct CacheEntry: Codable {
        let results: [ScoutLocation]
        let date: Date
    }

    private static let diskCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ScoutSearchResults", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // 1 year TTL — scouted locations don't change often, and re-billing the same
    // query in the same area is pure waste.
    private let cacheTTL: TimeInterval = 365 * 24 * 60 * 60

    // Hot in-memory layer so repeated searches within a session are instant.
    private var memoryCache: [CacheKey: CacheEntry] = [:]

    private func cachedEntry(for key: CacheKey) -> CacheEntry? {
        if let hit = memoryCache[key], Date().timeIntervalSince(hit.date) < cacheTTL { return hit }
        let url = Self.diskCacheDir.appendingPathComponent(key.diskFilename)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(CacheEntry.self, from: data),
              Date().timeIntervalSince(entry.date) < cacheTTL else { return nil }
        memoryCache[key] = entry   // warm the memory layer
        return entry
    }

    private func persist(_ entry: CacheEntry, for key: CacheKey) {
        memoryCache[key] = entry
        let url = Self.diskCacheDir.appendingPathComponent(key.diskFilename)
        try? JSONEncoder().encode(entry).write(to: url)
    }

    public struct MapRegion {
        public let centerLat: Double
        public let centerLng: Double
        public let latDelta: Double
        public let lngDelta: Double

        public init(centerLat: Double, centerLng: Double, latDelta: Double, lngDelta: Double) {
            self.centerLat = centerLat
            self.centerLng = centerLng
            self.latDelta = latDelta
            self.lngDelta = lngDelta
        }
    }

    public func search(query: String, region: MapRegion? = nil) async throws -> [ScoutLocation] {
        guard let apiKey else {
            dlog("No Google Maps API key set", level: .error, tag: "Places")
            throw PlacesError.missingAPIKey
        }

        let key = CacheKey(query: query, region: region)
        if let hit = cachedEntry(for: key) {
            dlog("Search cache hit: \"\(query)\" → \(hit.results.count) results (no API call)", level: .info, tag: "Places")
            return hit.results
        }

        if let region {
            dlog("Searching Places: \"\(query)\" restricted to \(String(format: "%.4f", region.centerLat)),\(String(format: "%.4f", region.centerLng)) ±\(String(format: "%.3f", region.latDelta))°", level: .network, tag: "Places")
        } else {
            dlog("Searching Places: \"\(query)\" (no location restriction)", level: .network, tag: "Places")
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")

        var body: [String: Any] = ["textQuery": query]
        if let region {
            let half = (region.latDelta / 2, region.lngDelta / 2)
            body["locationRestriction"] = [
                "rectangle": [
                    "low":  ["latitude": region.centerLat - half.0, "longitude": region.centerLng - half.1],
                    "high": ["latitude": region.centerLat + half.0, "longitude": region.centerLng + half.1],
                ]
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else { throw PlacesError.invalidResponse }

        let responseBody = String(data: data, encoding: .utf8) ?? ""
        dlog("Places response \(http.statusCode): \(responseBody.prefix(300))", level: http.statusCode == 200 ? .network : .error, tag: "Places")

        guard http.statusCode == 200 else {
            throw PlacesError.apiError(http.statusCode, responseBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let places = json["places"] as? [[String: Any]] else {
            dlog("No places in response", level: .warning, tag: "Places")
            return []
        }

        let locations = places.compactMap { parsePlace($0, apiKey: apiKey) }
        dlog("Found \(locations.count) locations", level: .success, tag: "Places")
        persist(CacheEntry(results: locations, date: Date()), for: key)
        return locations
    }

    private func parsePlace(_ place: [String: Any], apiKey: String) -> ScoutLocation? {
        guard let displayName = (place["displayName"] as? [String: Any])?["text"] as? String,
              let location = place["location"] as? [String: Any],
              let lat = location["latitude"] as? Double,
              let lng = location["longitude"] as? Double else {
            dlog("Failed to parse place: \(place.keys.joined(separator: ","))", level: .warning, tag: "Places")
            return nil
        }

        let placeId = place["id"] as? String
        let address = place["formattedAddress"] as? String ?? ""
        let mapsURI = (place["googleMapsUri"] as? String).flatMap(URL.init)

        // Build photo URLs WITHOUT the API key baked in — the key is added as a header
        // at load time (same as the search request) to avoid key-config failures with
        // bare URL+key query param loading.
        let photoRefs = place["photos"] as? [[String: Any]] ?? []
        // One photo per search result. The carousel fetches the rest on demand via
        // fetchPhotos(for:placeId) only when the user opens it.
        let images: [ScoutImage] = photoRefs.prefix(1).compactMap { photo in
            guard let name = photo["name"] as? String else { return nil }
            let urlStr = "https://places.googleapis.com/v1/\(name)/media?maxWidthPx=800"
            return URL(string: urlStr).map { ScoutImage(url: $0, source: .googleMaps) }
        }

        dlog("Parsed: \(displayName) @ \(lat),\(lng) — \(images.count) photos", level: .info, tag: "Places")

        return ScoutLocation(
            name: displayName,
            description: address,
            coordinate: .init(latitude: lat, longitude: lng),
            images: images,
            googleMapsURL: mapsURI,
            googlePlaceId: placeId
        )
    }

    /// Fetches the photo list for a known place ID (for pins that were saved without a photo URL).
    public func fetchPhotos(for placeId: String) async throws -> [ScoutImage] {
        guard let apiKey else { throw PlacesError.missingAPIKey }
        let url = URL(string: "https://places.googleapis.com/v1/places/\(placeId)?fields=photos")!
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photoRefs = json["photos"] as? [[String: Any]] else { return [] }
        return photoRefs.prefix(5).compactMap { photo in
            guard let name = photo["name"] as? String else { return nil }
            let urlStr = "https://places.googleapis.com/v1/\(name)/media?maxWidthPx=800"
            return URL(string: urlStr).map { ScoutImage(url: $0, source: .googleMaps) }
        }
    }

    public enum PlacesError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(Int, String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No Google Maps API key set. Add one in Settings."
            case .invalidResponse: return "Invalid response from Google Places."
            case .apiError(let code, let body): return "Google Places error \(code): \(body)"
            }
        }
    }
}
