import Foundation
import CoreLocation

/// Searches Wikimedia Commons for geotagged photos.
/// No API key required — Commons is free and open.
public final class WikimediaService {
    public static let shared = WikimediaService()
    private init() {}

    private let base = "https://commons.wikimedia.org/w/api.php"

    public func search(query: String, region: GooglePlacesService.MapRegion? = nil, limit: Int = 50) async throws -> [ScoutLocation] {
        if let r = region {
            return try await geoSearch(query: query, region: r, limit: limit)
        } else {
            return try await textSearch(query: query, limit: limit)
        }
    }

    // MARK: - Geosearch (has map region → guaranteed coordinates)

    private func geoSearch(query: String, region: GooglePlacesService.MapRegion, limit: Int) async throws -> [ScoutLocation] {
        // Derive radius from region size; Wikimedia max is 10 000 m
        let latM = region.latDelta * 111_000
        let lngM = region.lngDelta * 111_000 * cos(region.centerLat * .pi / 180)
        let radius = max(100, min(min(latM, lngM) / 2, 10_000))

        let params: [URLQueryItem] = [
            .init(name: "action",       value: "query"),
            .init(name: "generator",    value: "geosearch"),
            .init(name: "ggscoord",     value: "\(region.centerLat)|\(region.centerLng)"),
            .init(name: "ggsradius",    value: "\(Int(radius))"),
            .init(name: "ggslimit",     value: "\(min(limit, 500))"),
            .init(name: "ggsnamespace", value: "6"),
            .init(name: "prop",         value: "imageinfo|coordinates"),
            .init(name: "iiprop",       value: "url|extmetadata"),
            .init(name: "iiurlwidth",   value: "1200"),
            .init(name: "format",       value: "json"),
            .init(name: "origin",       value: "*"),
        ]

        let pages = try await fetchPages(params: params)

        return pages.values.compactMap { page in
            guard isImageFile(page.title),
                  let coord = page.coordinates?.first,
                  let info = page.imageinfo?.first else { return nil }

            return makeLocation(
                title: page.title,
                lat: coord.lat, lng: coord.lon,
                info: info
            )
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Text search (no region → no coordinate guarantee, show what we can)

    private func textSearch(query: String, limit: Int) async throws -> [ScoutLocation] {
        let params: [URLQueryItem] = [
            .init(name: "action",       value: "query"),
            .init(name: "generator",    value: "search"),
            .init(name: "gsrsearch",    value: query),
            .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrlimit",     value: "\(min(limit, 500))"),
            .init(name: "prop",         value: "imageinfo|coordinates"),
            .init(name: "iiprop",       value: "url|extmetadata"),
            .init(name: "iiurlwidth",   value: "1200"),
            .init(name: "format",       value: "json"),
            .init(name: "origin",       value: "*"),
        ]

        let pages = try await fetchPages(params: params)

        return pages.values.compactMap { page in
            guard isImageFile(page.title),
                  let info = page.imageinfo?.first,
                  let thumbURL = info.thumburl.flatMap(URL.init) else { return nil }

            // Use coordinates if available; otherwise place at (0,0) and caller can filter
            let lat = page.coordinates?.first?.lat
            let lng = page.coordinates?.first?.lon
            guard let lat, let lng, lat != 0 || lng != 0 else { return nil }

            return makeLocation(title: page.title, lat: lat, lng: lng, info: info)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Shared helpers

    private func fetchPages(params: [URLQueryItem]) async throws -> [String: WikiPage] {
        var comps = URLComponents(string: base)!
        comps.queryItems = params
        guard let url = comps.url else { throw WikimediaError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WikimediaError.httpError(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(WikimediaResponse.self, from: data)
        return decoded.query?.pages ?? [:]
    }

    private func isImageFile(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") ||
               lower.hasSuffix(".png") || lower.hasSuffix(".webp")
    }

    private func makeLocation(title: String, lat: Double, lng: Double, info: WikiImageInfo) -> ScoutLocation {
        let meta = info.extmetadata
        let description = stripHTML(meta?.ImageDescription?.value ?? "")
        let artist = stripHTML(meta?.Artist?.value ?? "")
        let displayName = title
            .replacingOccurrences(of: "File:", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: ".").dropLast().joined(separator: ".")
            .trimmingCharacters(in: .whitespaces)

        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        let pageURL  = URL(string: "https://commons.wikimedia.org/wiki/\(encoded)")
        let mapsURL  = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)")
        let imageURL = info.thumburl.flatMap(URL.init) ?? URL(string: info.url)!

        return ScoutLocation(
            name: displayName.isEmpty ? "Wikimedia Photo" : displayName,
            description: description.isEmpty ? artist : description,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            sourceURL: pageURL,
            images: [ScoutImage(url: imageURL, source: .googleMaps)],
            googleMapsURL: mapsURL
        )
    }

    private func stripHTML(_ string: String) -> String {
        guard string.contains("<") else { return string }
        let result: String
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            result = regex.stringByReplacingMatches(
                in: string,
                range: NSRange(string.startIndex..., in: string),
                withTemplate: ""
            )
        } else {
            result = string
        }
        return result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response types

    private struct WikimediaResponse: Decodable {
        let query: QueryResult?
        struct QueryResult: Decodable {
            let pages: [String: WikiPage]
        }
    }

    private struct WikiPage: Decodable {
        let title: String
        let imageinfo: [WikiImageInfo]?
        let coordinates: [WikiCoordinate]?
    }

    private struct WikiImageInfo: Decodable {
        let url: String
        let thumburl: String?
        let extmetadata: WikiExtMetadata?
    }

    private struct WikiExtMetadata: Decodable {
        let ImageDescription: WikiMetaValue?
        let Artist: WikiMetaValue?
    }

    private struct WikiMetaValue: Decodable {
        let value: String
    }

    private struct WikiCoordinate: Decodable {
        let lat: Double
        let lon: Double
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
