import Foundation
import CoreLocation

public final class FlickrService {
    public static let shared = FlickrService()
    private init() {}

    private let base = "https://www.flickr.com/services/rest/"

    private var apiKey: String {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "debug.com.scout.app.flickr_api_key") ?? ""
        #else
        return KeychainService.load(forKey: KeychainService.flickrAPIKey) ?? ""
        #endif
    }

    public func search(query: String, region: GooglePlacesService.MapRegion? = nil) async throws -> [ScoutLocation] {
        let key = apiKey
        guard !key.isEmpty else { throw FlickrError.noAPIKey }

        var params: [URLQueryItem] = [
            .init(name: "method",         value: "flickr.photos.search"),
            .init(name: "api_key",        value: key),
            .init(name: "text",           value: query),
            .init(name: "has_geo",        value: "1"),
            .init(name: "geo_context",    value: "2"),   // outdoors
            .init(name: "content_type",   value: "1"),   // photos only
            .init(name: "extras",         value: "url_l,url_m,geo,description,owner_name,views"),
            .init(name: "sort",           value: "relevance"),
            .init(name: "per_page",       value: "24"),
            .init(name: "format",         value: "json"),
            .init(name: "nojsoncallback", value: "1"),
        ]

        if let r = region {
            let half_lat = r.latDelta / 2
            let half_lng = r.lngDelta / 2
            let bbox = "\(r.centerLng - half_lng),\(r.centerLat - half_lat),\(r.centerLng + half_lng),\(r.centerLat + half_lat)"
            params.append(.init(name: "bbox", value: bbox))
        }

        var comps = URLComponents(string: base)!
        comps.queryItems = params
        guard let url = comps.url else { throw FlickrError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw FlickrError.httpError(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(FlickrResponse.self, from: data)
        guard decoded.stat == "ok" else { throw FlickrError.apiError(decoded.message ?? "Unknown error") }

        return decoded.photos.photo.compactMap { photo in
            guard let lat = Double(photo.latitude ?? ""),
                  let lng = Double(photo.longitude ?? ""),
                  lat != 0 || lng != 0 else { return nil }

            let imageURL = photo.url_l ?? photo.url_m
            let images: [ScoutImage] = imageURL.map {
                [ScoutImage(url: URL(string: $0), source: .googleMaps)]
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
        let photos: PhotosContainer

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

            struct DescriptionContent: Decodable {
                let _content: String
            }
        }
    }

    public enum FlickrError: LocalizedError {
        case noAPIKey
        case badURL
        case httpError(Int)
        case apiError(String)

        public var errorDescription: String? {
            switch self {
            case .noAPIKey:         return "Flickr API key not set. Add it in Settings."
            case .badURL:           return "Invalid request URL."
            case .httpError(let c): return "Flickr returned HTTP \(c)."
            case .apiError(let m):  return "Flickr error: \(m)"
            }
        }
    }
}
