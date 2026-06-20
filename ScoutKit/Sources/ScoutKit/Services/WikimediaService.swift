import Foundation
import CoreLocation

/// Searches Wikimedia Commons for geotagged photos matching a text query.
/// No API key required — Commons is free and open.
public final class WikimediaService {
    public static let shared = WikimediaService()
    private init() {}

    private let base = "https://commons.wikimedia.org/w/api.php"
    private let thumbWidth = 1200

    public func search(query: String, region: GooglePlacesService.MapRegion? = nil) async throws -> [ScoutLocation] {
        // Build the request — generator=search finds File: pages matching the query.
        // prop=coordinates filters to geotagged files only.
        var params: [URLQueryItem] = [
            .init(name: "action",       value: "query"),
            .init(name: "generator",    value: "search"),
            .init(name: "gsrsearch",    value: query),
            .init(name: "gsrnamespace", value: "6"),       // File namespace
            .init(name: "gsrlimit",     value: "30"),
            .init(name: "prop",         value: "imageinfo|coordinates"),
            .init(name: "iiprop",       value: "url|extmetadata|size"),
            .init(name: "iiurlwidth",   value: "\(thumbWidth)"),
            .init(name: "format",       value: "json"),
            .init(name: "origin",       value: "*"),
        ]

        // If we have a region, add coordinate-based filtering via a second search pass.
        // Wikimedia doesn't support combined text+geo in one call, so we use text search
        // and then filter client-side by the returned coordinates.
        var comps = URLComponents(string: base)!
        comps.queryItems = params
        guard let url = comps.url else { throw WikimediaError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WikimediaError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(WikimediaResponse.self, from: data)
        guard let pages = decoded.query?.pages else { return [] }

        var results: [ScoutLocation] = []

        for page in pages.values {
            // Only include pages that have geographic coordinates
            guard let coord = page.coordinates?.first,
                  let info  = page.imageinfo?.first else { continue }

            let lat = coord.lat, lng = coord.lon

            // Client-side region filter
            if let r = region {
                let halfLat = r.latDelta / 2, halfLng = r.lngDelta / 2
                let inLat = lat >= r.centerLat - halfLat && lat <= r.centerLat + halfLat
                let inLng = lng >= r.centerLng - halfLng && lng <= r.centerLng + halfLng
                guard inLat && inLng else { continue }
            }

            // Skip non-image files (SVG diagrams, audio, etc.)
            let title = page.title
            let lower = title.lowercased()
            guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ||
                  lower.hasSuffix(".png") || lower.hasSuffix(".webp") else { continue }

            // Extract metadata
            let meta = info.extmetadata
            let rawDesc = meta?.ImageDescription?.value ?? ""
            let description = stripHTML(rawDesc)
            let artist = stripHTML(meta?.Artist?.value ?? "")
            let displayName = title
                .replacingOccurrences(of: "File:", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .components(separatedBy: ".").dropLast().joined(separator: ".")
                .trimmingCharacters(in: .whitespaces)

            let imageURL = URL(string: info.thumburl ?? info.url)
            let pageURL  = URL(string: "https://commons.wikimedia.org/wiki/\(title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)")
            let mapsURL  = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)")

            let loc = ScoutLocation(
                name: displayName.isEmpty ? "Wikimedia Photo" : displayName,
                description: description.isEmpty ? artist : description,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                sourceURL: pageURL,
                images: imageURL.map { [ScoutImage(url: $0, source: .googleMaps)] } ?? [],
                googleMapsURL: mapsURL
            )
            results.append(loc)
        }

        // Stable order: sort by title so results don't shuffle on re-search
        return results.sorted { $0.name < $1.name }
    }

    // MARK: - Helpers

    private func stripHTML(_ string: String) -> String {
        guard string.contains("<") else { return string }
        var result = string
        // Remove tags
        while let open = result.range(of: "<"), let close = result.range(of: ">", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound...close.upperBound)
        }
        return result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response types

    private struct WikimediaResponse: Decodable {
        let query: QueryResult?
        struct QueryResult: Decodable {
            let pages: [String: Page]
        }
        struct Page: Decodable {
            let title: String
            let imageinfo: [ImageInfo]?
            let coordinates: [Coordinate]?
        }
        struct ImageInfo: Decodable {
            let url: String
            let thumburl: String?
            let extmetadata: ExtMetadata?
        }
        struct ExtMetadata: Decodable {
            let ImageDescription: MetaValue?
            let Artist: MetaValue?
        }
        struct MetaValue: Decodable {
            let value: String
        }
        struct Coordinate: Decodable {
            let lat: Double
            let lon: Double
        }
    }

    public enum WikimediaError: LocalizedError {
        case badURL
        case httpError(Int)
        public var errorDescription: String? {
            switch self {
            case .badURL:           return "Invalid request URL."
            case .httpError(let c): return "Wikimedia returned HTTP \(c)."
            }
        }
    }
}
