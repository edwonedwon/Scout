import Foundation
import CoreLocation

public final class FoursquareService {
    public static let shared = FoursquareService()
    private init() {}

    private let base = URL(string: "https://api.foursquare.com/v3/places/search")!

    private var apiKey: String {
        KeychainService.load(forKey: KeychainService.foursquareAPIKey) ?? ""
    }

    public func search(
        query: String? = nil,
        region: GooglePlacesService.MapRegion? = nil,
        limit: Int = 50
    ) async throws -> [ScoutLocation] {
        let key = apiKey
        guard !key.isEmpty else { throw FoursquareError.noAPIKey }

        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "limit", value: "\(min(max(limit, 1), 50))"),
            .init(name: "fields", value: "fsq_id,name,geocodes,location,photos,description,website"),
        ]
        if let q = query, !q.isEmpty {
            items.append(.init(name: "query", value: q))
        }
        if let r = region {
            items.append(.init(name: "ll",     value: "\(r.centerLat),\(r.centerLng)"))
            // Convert degree span to metres radius; clamp to 50 km max.
            let radiusM = min(Int(r.latDelta * 111_000 / 2), 50_000)
            items.append(.init(name: "radius", value: "\(max(radiusM, 100))"))
        }
        comps.queryItems = items

        guard let url = comps.url else { throw FoursquareError.badURL }
        var request = URLRequest(url: url)
        request.setValue(key,                forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FoursquareError.invalidResponse }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FoursquareError.apiError(http.statusCode, body)
        }

        guard let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["results"] as? [[String: Any]] else { return [] }

        return items.compactMap { parsePlace($0) }
    }

    private func parsePlace(_ place: [String: Any]) -> ScoutLocation? {
        guard let name = place["name"] as? String,
              let geo  = place["geocodes"] as? [String: Any],
              let main = geo["main"] as? [String: Any],
              let lat  = main["latitude"]  as? Double,
              let lng  = main["longitude"] as? Double else { return nil }

        let placeId = place["fsq_id"] as? String
        let desc    = (place["location"] as? [String: Any])?["formatted_address"] as? String ?? ""

        // Build photo URLs from the first photo object.
        var images: [ScoutImage] = []
        if let photos = place["photos"] as? [[String: Any]],
           let first = photos.first,
           let prefix = first["prefix"] as? String,
           let suffix = first["suffix"] as? String,
           let url = URL(string: "\(prefix)800x600\(suffix)") {
            images = [ScoutImage(url: url, source: .googleMaps)]
        }

        return ScoutLocation(
            name: name,
            description: desc,
            coordinate: .init(latitude: lat, longitude: lng),
            images: images,
            googlePlaceId: placeId,
            status: .scouted
        )
    }

    public enum FoursquareError: LocalizedError {
        case noAPIKey, noRegion, badURL, invalidResponse
        case apiError(Int, String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey:          return "No Foursquare API key set. Add one in Settings."
            case .noRegion:          return "A search query or map region is required."
            case .badURL:            return "Could not build Foursquare request URL."
            case .invalidResponse:   return "Invalid response from Foursquare."
            case .apiError(let c, let b): return "Foursquare error \(c): \(b)"
            }
        }
    }
}
