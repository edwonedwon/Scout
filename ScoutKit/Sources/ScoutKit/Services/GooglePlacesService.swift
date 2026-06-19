import Foundation
import CoreLocation

public actor GooglePlacesService {
    public static let shared = GooglePlacesService()

    private let baseURL = URL(string: "https://places.googleapis.com/v1/places:searchText")!
    private let fieldMask = "places.id,places.displayName,places.location,places.formattedAddress,places.googleMapsUri,places.rating,places.userRatingCount"

    private var apiKey: String? {
        KeychainService.load(forKey: KeychainService.googleMapsAPIKey)
    }

    public func search(query: String) async throws -> [ScoutLocation] {
        guard let apiKey else {
            dlog("No Google Maps API key set", level: .error, tag: "Places")
            throw PlacesError.missingAPIKey
        }

        dlog("Searching Places: \"\(query)\"", level: .network, tag: "Places")

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(fieldMask, forHTTPHeaderField: "X-Goog-FieldMask")

        let body: [String: Any] = ["textQuery": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PlacesError.invalidResponse
        }

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

        let locations = places.compactMap { parsePlace($0) }
        dlog("Found \(locations.count) locations", level: .success, tag: "Places")
        return locations
    }

    private func parsePlace(_ place: [String: Any]) -> ScoutLocation? {
        guard let displayName = (place["displayName"] as? [String: Any])?["text"] as? String,
              let location = place["location"] as? [String: Any],
              let lat = location["latitude"] as? Double,
              let lng = location["longitude"] as? Double else {
            dlog("Failed to parse place: \(place.keys.joined(separator: ","))", level: .warning, tag: "Places")
            return nil
        }

        let address = place["formattedAddress"] as? String ?? ""
        let mapsURI = (place["googleMapsUri"] as? String).flatMap(URL.init)

        dlog("Parsed: \(displayName) @ \(lat),\(lng)", level: .info, tag: "Places")

        return ScoutLocation(
            name: displayName,
            description: address,
            coordinate: .init(latitude: lat, longitude: lng),
            googleMapsURL: mapsURI
        )
    }

    public enum PlacesError: LocalizedError {
        case missingAPIKey
        case invalidResponse
        case apiError(Int, String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Google Maps API key set. Add one in Settings."
            case .invalidResponse:
                return "Invalid response from Google Places."
            case .apiError(let code, let body):
                return "Google Places error \(code): \(body)"
            }
        }
    }
}
