import Foundation
import CoreLocation
import ImageIO
import ScoutKit
import UniformTypeIdentifiers

// MARK: - Photo import

/// Reads a photo file from disk, extracts EXIF GPS + date, copies it to the Scout
/// offline photo directory, and creates a `PinnedLocationData` ready to insert.
///
/// Photos without GPS data (`hasGPS = false`) are stored in the list but not shown
/// on the map. `dateTaken` is preserved for a future Google Timeline sync pass that
/// will derive coordinates from movement data matched to the capture timestamp.
@MainActor
enum PhotoImportService {

    struct ImportResult {
        /// The created pin, not yet inserted into the model context.
        var pin: PinnedLocationData
        /// True if the photo had GPS EXIF data.
        var hadGPS: Bool
    }

    /// Imports photos from the given file URLs into a list (or as unfiled pins if list
    /// is nil). Returns results for each successfully read photo. Caller must insert the
    /// pins into a `ModelContext` and set `pin.list` as needed.
    static func importPhotos(from urls: [URL], into list: LocationListData?) async -> [ImportResult] {
        var results: [ImportResult] = []
        for (order, url) in urls.enumerated() {
            // startAccessingSecurityScopedResource returns false for non-scoped URLs
            // (e.g. debug builds without sandbox) — call it but never skip on false.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let result = await importOne(url: url, sortOrder: (list?.pins.count ?? 0) + order) else { continue }
            results.append(result)
        }
        return results
    }

    private static func importOne(url: URL, sortOrder: Int) async -> ImportResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // GPS
        var coordinate: CLLocationCoordinate2D? = nil
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lng = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lngRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            let validLat = latRef == "S" ? -lat : lat
            let validLng = lngRef == "W" ? -lng : lng
            if CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: validLat, longitude: validLng)) {
                coordinate = CLLocationCoordinate2D(latitude: validLat, longitude: validLng)
            }
        }

        // Date taken from EXIF
        var dateTaken: Date? = nil
        let exifFmt = DateFormatter()
        exifFmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let dateStr = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            dateTaken = exifFmt.date(from: dateStr)
        } else if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
                  let dateStr = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            dateTaken = exifFmt.date(from: dateStr)
        }

        // Copy photo file into the offline directory
        let ext = url.pathExtension.lowercased()
        let filename = "\(UUID().uuidString).\(ext.isEmpty ? "jpg" : ext)"
        let dest = PinPhotoStore.directory.appendingPathComponent(filename)
        guard (try? data.write(to: dest)) != nil else { return nil }

        // Build a name from the filename (strip UUID-ness later if needed)
        let displayName = url.deletingPathExtension().lastPathComponent

        let pin = PinnedLocationData.fromImport(
            name: displayName,
            coordinate: coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
            hasGPS: coordinate != nil,
            dateTaken: dateTaken,
            photoFilename: filename,
            sortOrder: sortOrder
        )
        return ImportResult(pin: pin, hadGPS: coordinate != nil)
    }
}

// MARK: - Factory for imported photos

extension PinnedLocationData {
    /// Creates a pin from an imported photo. Pass hasGPS = false for photos with no EXIF GPS.
    static func fromImport(name: String, coordinate: CLLocationCoordinate2D,
                           hasGPS: Bool, dateTaken: Date?, photoFilename: String, sortOrder: Int) -> PinnedLocationData {
        let phantom = ScoutLocation(
            name: name,
            description: "",
            coordinate: coordinate,
            images: []
        )
        let pin = PinnedLocationData(from: phantom, sortOrder: sortOrder)
        pin.imageSourceRaw = ScoutImage.ImageSource.imported.rawValue
        pin.photoFiles = [photoFilename]
        pin.hasGPS = hasGPS
        pin.dateTaken = dateTaken
        return pin
    }
}
