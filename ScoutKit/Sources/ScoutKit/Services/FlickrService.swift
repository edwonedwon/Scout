import Foundation
import CoreLocation

public final class FlickrService {
    public static let shared = FlickrService()
    private init() {}

    private let base = "https://www.flickr.com/services/rest/"

    private static let flickrDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var apiKey: String {
        KeychainService.load(forKey: KeychainService.flickrAPIKey) ?? ""
    }

    public func search(query: String? = nil, region: GooglePlacesService.MapRegion? = nil, limit: Int = 50) async throws -> [ScoutLocation] {
        let key = apiKey
        guard !key.isEmpty else { throw FlickrError.noAPIKey }
        // When no query and no region there's nothing to scope the search
        guard query != nil || region != nil else { throw FlickrError.noRegion }

        var params: [URLQueryItem] = [
            .init(name: "method",         value: "flickr.photos.search"),
            .init(name: "api_key",        value: key),
            .init(name: "has_geo",        value: "1"),
            .init(name: "content_type",   value: "1"),   // photos only
            .init(name: "media",          value: "photos"),
            .init(name: "extras",         value: "url_l,url_m,geo,description,owner_name,views,date_taken"),
            .init(name: "sort",           value: query == nil ? "interestingness-desc" : "relevance"),
            .init(name: "per_page",       value: "\(min(max(limit, 1), 500))"),
            .init(name: "format",         value: "json"),
            .init(name: "nojsoncallback", value: "1"),
        ]
        if let query { params.append(.init(name: "text", value: query)) }

        if let r = region {
            let half_lat = r.latDelta / 2
            let half_lng = r.lngDelta / 2
            // Flickr rejects bbox searches spanning a very large area; clamp the
            // half-spans so an over-zoomed-out map still returns results.
            let clamped_lat = min(half_lat, 1.0)
            let clamped_lng = min(half_lng, 1.0)
            let minLng = max(r.centerLng - clamped_lng, -180)
            let minLat = max(r.centerLat - clamped_lat, -90)
            let maxLng = min(r.centerLng + clamped_lng, 180)
            let maxLat = min(r.centerLat + clamped_lat, 90)
            params.append(.init(name: "bbox", value: "\(minLng),\(minLat),\(maxLng),\(maxLat)"))
            // Flickr requires a date or accuracy constraint alongside bbox-only
            // searches; an accuracy floor keeps the search valid without a query.
            if query == nil {
                params.append(.init(name: "accuracy", value: "6"))
            }
        }

        var comps = URLComponents(string: base)!
        comps.queryItems = params
        guard let url = comps.url else { throw FlickrError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FlickrError.httpError(http.statusCode)
        }

        #if DEBUG
        if let raw = String(data: data, encoding: .utf8) {
            print("[Flickr] response: \(raw.prefix(500))")
        }
        #endif

        let decoded = try JSONDecoder().decode(FlickrResponse.self, from: data)
        guard decoded.stat == "ok" else { throw FlickrError.apiError(decoded.message ?? "Unknown error") }

        return (decoded.photos?.photo ?? []).compactMap { photo in
            guard let lat = Double(photo.latitude ?? ""),
                  let lng = Double(photo.longitude ?? ""),
                  lat != 0 || lng != 0 else { return nil }

            let imageURL = photo.url_l ?? photo.url_m
            let dateTaken = photo.datetaken.flatMap { FlickrService.flickrDateFormatter.date(from: $0) }
            let images: [ScoutImage] = imageURL.map {
                [ScoutImage(url: URL(string: $0), source: .googleMaps, dateTaken: dateTaken)]
            } ?? []

            let pageURL = URL(string: "https://www.flickr.com/photos/\(photo.owner)/\(photo.id)")
            let mapsURL = URL(string: "https://www.google.com/maps/search/?api=1&query=\(lat),\(lng)")
            let desc = photo.description?._content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return ScoutLocation(
                name: photo.title.isEmpty ? "Untitled" : photo.title,
                description: desc.isEmpty ? (photo.ownername ?? "") : desc,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                sourceURL: pageURL,
                images: images,
                googleMapsURL: mapsURL
            )
        }
    }

    // MARK: - Response types

    private struct FlickrResponse: Decodable {
        let stat: String
        let message: String?
        let photos: PhotosContainer?   // absent on error responses

        struct PhotosContainer: Decodable {
            let photo: [Photo]
        }

        struct Photo: Decodable {
            let id: String
            let owner: String
            let title: String
            let ownername: String?
            let latitude: String?
            let longitude: String?
            let url_l: String?
            let url_m: String?
            let description: DescriptionContent?
            let datetaken: String?   // "2023-07-14 10:32:01"

            struct DescriptionContent: Decodable {
                let _content: String
            }
        }
    }

    public enum FlickrError: LocalizedError {
        case noAPIKey
        case noRegion
        case badURL
        case httpError(Int)
        case apiError(String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey:         return "Flickr API key not set. Add it in Settings."
            case .noRegion:         return "Move the map to an area first, then browse."
            case .badURL:           return "Invalid request URL."
            case .httpError(let c): return "Flickr returned HTTP \(c)."
            case .apiError(let m):  return "Flickr error: \(m)"
            }
        }
    }
}
