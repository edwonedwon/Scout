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
        let images: [ScoutImage] = photoRefs.prefix(5).compactMap { photo in
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
