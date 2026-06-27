import Foundation
import CoreData
import CoreLocation
import ImageIO
import CoreGraphics
import ScoutKit
import UniformTypeIdentifiers

// MARK: - Photo import

/// Reads a photo file from disk, extracts EXIF metadata, produces a compressed full-res
/// JPEG (2048px) and a thumbnail JPEG (300px), stores those in the app container, and
/// records the original file path for carousel use when the file is still available.
///
/// The original file is NEVER copied — only its path is stored. Photos without GPS
/// (`hasGPS = false`) appear in the list/timeline but not on the map.
@MainActor
enum PhotoImportService {

    /// A fully-processed import (files already written to disk) described with plain values —
    /// NO managed object. Core Data objects must be created on the main/view-context thread, so
    /// `importPhotos` runs entirely off-thread and the caller materializes the pin via `makePin`.
    struct ImportResult {
        var id: UUID
        var name: String
        var coordinate: CLLocationCoordinate2D
        var hasGPS: Bool
        var dateTaken: Date?
        var originalFilePath: String
        var fullFilename: String
        var thumbFilename: String
        var sortOrder: Int
        var aspectRatio: Double
        var hadGPS: Bool

        /// Materializes this import as a managed object in `context` (call on the main thread).
        @discardableResult
        func makePin(in context: NSManagedObjectContext) -> PinnedLocationData {
            PinnedLocationData.fromImport(
                context: context, id: id, name: name, coordinate: coordinate, hasGPS: hasGPS,
                dateTaken: dateTaken, originalFilePath: originalFilePath, fullFilename: fullFilename,
                thumbFilename: thumbFilename, sortOrder: sortOrder, aspectRatio: aspectRatio)
        }
    }

    // MARK: - Public entry point

    /// Imports photos from `urls`, skipping any that already exist in `existingPins`.
    /// Duplicate detection uses three fast O(1) checks built from `existingPins` once:
    ///  1. Exact filename of the original file path.
    ///  2. Same date-taken (±1 s) AND same GPS (±0.0001°, ≈10 m).
    ///  3. Same date-taken (±1 s) AND same display name (for GPS-less photos).
    /// Dedup indexes for an import, built from existing pins ON THE MAIN THREAD (managed-object
    /// access) before kicking off the off-thread `importPhotos`.
    struct DedupIndex {
        var filenames: Set<String> = []
        var dateGPS:   Set<String> = []   // "timestamp|lat4|lng4"
        var dateName:  Set<String> = []   // "timestamp|name"   (GPS-less fallback)

        @MainActor
        init(existingPins: [PinnedLocationData]) {
            for pin in existingPins {
                if let path = pin.originalFilePath {
                    filenames.insert(URL(fileURLWithPath: path).lastPathComponent)
                }
                if let d = pin.dateTaken {
                    let ts = String(Int(d.timeIntervalSinceReferenceDate))
                    if pin.hasGPS {
                        let lat = String(format: "%.4f", pin.latitude)
                        let lng = String(format: "%.4f", pin.longitude)
                        dateGPS.insert("\(ts)|\(lat)|\(lng)")
                    } else {
                        dateName.insert("\(ts)|\(pin.name)")
                    }
                }
            }
        }
    }

    static func importPhotos(from urls: [URL],
                             dedup: DedupIndex,
                             baseSortOrder: Int,
                             onProgress: (@MainActor (Int, Int) -> Void)? = nil) async -> [ImportResult] {
        var results: [ImportResult] = []
        let total = urls.count
        for (order, url) in urls.enumerated() {
            await onProgress?(order, total)
            // Fast filename check before touching the file.
            if dedup.filenames.contains(url.lastPathComponent) { continue }

            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let result = await importOne(url: url,
                                               sortOrder: baseSortOrder + order,
                                               existingDateGPS: dedup.dateGPS,
                                               existingDateName: dedup.dateName)
            else { continue }
            results.append(result)
        }
        return results
    }

    // MARK: - Single file

    private static func importOne(url: URL, sortOrder: Int,
                                   existingDateGPS: Set<String> = [],
                                   existingDateName: Set<String> = []) async -> ImportResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]

        // --- GPS ---
        var coordinate: CLLocationCoordinate2D? = nil
        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lng = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lngRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            let signedLat = latRef == "S" ? -lat : lat
            let signedLng = lngRef == "W" ? -lng : lng
            let candidate = CLLocationCoordinate2D(latitude: signedLat, longitude: signedLng)
            if CLLocationCoordinate2DIsValid(candidate) { coordinate = candidate }
        }

        // --- Date taken ---
        var dateTaken: Date? = nil
        let exifFmt = DateFormatter()
        exifFmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let str = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            dateTaken = exifFmt.date(from: str)
        } else if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
                  let str = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            dateTaken = exifFmt.date(from: str)
        }

        // --- Duplicate check on EXIF data (before any disk writes) ---
        if let d = dateTaken {
            let ts = String(Int(d.timeIntervalSinceReferenceDate))
            if let coord = coordinate {
                let lat = String(format: "%.4f", coord.latitude)
                let lng = String(format: "%.4f", coord.longitude)
                if existingDateGPS.contains("\(ts)|\(lat)|\(lng)") { return nil }
            } else {
                let name = url.deletingPathExtension().lastPathComponent
                if existingDateName.contains("\(ts)|\(name)") { return nil }
            }
        }

        // --- Decode pixel data (handles RAW, HEIC, HEIF, TIFF, JPEG, etc.) ---
        // kCGImageSourceDecodeToHDR + kCGImageSourceAllowFloat aren't needed for SDR output;
        // kCGImageSourceSubsampleFactor 1 ensures full-resolution decode of RAW files.
        let decodeOpts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceSubsampleFactor: 1,
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, decodeOpts as CFDictionary) else { return nil }

        let pinID = UUID()

        // Compressed full-res (2048px longest side, 0.82 quality)
        guard let fullData = compress(cgImage, maxDimension: 2048, quality: 0.82),
              let fullName = write(fullData, name: "\(pinID.uuidString)-0-full.jpg") else { return nil }

        // Thumbnail (300px longest side, 0.65 quality)
        guard let thumbData = compress(cgImage, maxDimension: 300, quality: 0.65),
              let thumbName = write(thumbData, name: "\(pinID.uuidString)-0-thumb.jpg") else { return nil }

        let displayName = url.deletingPathExtension().lastPathComponent
        let aspect = cgImage.height > 0 ? Double(cgImage.width) / Double(cgImage.height) : 0
        return ImportResult(
            id: pinID,
            name: displayName,
            coordinate: coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0),
            hasGPS: coordinate != nil,
            dateTaken: dateTaken,
            originalFilePath: url.path,
            fullFilename: fullName,
            thumbFilename: thumbName,
            sortOrder: sortOrder,
            aspectRatio: aspect,
            hadGPS: coordinate != nil
        )
    }

    // MARK: - Compression

    /// Downscales `image` so its longest side ≤ `maxDimension`, then JPEG-encodes it.
    nonisolated private static func compress(_ image: CGImage, maxDimension: Int, quality: CGFloat) -> Data? {
        let w = image.width, h = image.height
        let scale = min(1.0, CGFloat(maxDimension) / CGFloat(max(w, h)))
        let newW = Int((CGFloat(w) * scale).rounded())
        let newH = Int((CGFloat(h) * scale).rounded())

        // Draw into a new bitmap context at the target size.
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaled = ctx.makeImage() else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    nonisolated private static func write(_ data: Data, name: String) -> String? {
        let dest = PinPhotoStore.directory.appendingPathComponent(name)
        guard (try? data.write(to: dest)) != nil else { return nil }
        return name
    }

    // MARK: - Relink support (off-main helpers)

    /// Lightweight metadata read from an image's header WITHOUT decoding pixels — used to match
    /// original files against existing pins during relink.
    struct OriginalMeta {
        var url: URL
        var filename: String
        var dateTaken: Date?
        var coordinate: CLLocationCoordinate2D?
        var aspect: Double?
        /// File extension lowercased (e.g. "hif") — lets the matcher prefer camera-original formats.
        var ext: String
    }

    /// Image file extensions we treat as "originals" worth scanning for (camera RAW + HEIF + common).
    static let originalExtensions: Set<String> = [
        "jpg","jpeg","heic","heif","hif","png","tif","tiff",
        "arw","cr2","cr3","nef","dng","raw","orf","rw2",
    ]

    /// Reads filename + EXIF date + GPS + aspect ratio from a file's header (no pixel decode).
    nonisolated static func readOriginalMeta(at url: URL) -> OriginalMeta {
        var meta = OriginalMeta(url: url, filename: url.lastPathComponent, dateTaken: nil,
                                coordinate: nil, aspect: nil, ext: url.pathExtension.lowercased())
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return meta }

        if let w = props[kCGImagePropertyPixelWidth as String] as? Double,
           let h = props[kCGImagePropertyPixelHeight as String] as? Double, h > 0 {
            meta.aspect = w / h
        }

        if let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lng = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lngRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            let c = CLLocationCoordinate2D(latitude: latRef == "S" ? -lat : lat,
                                           longitude: lngRef == "W" ? -lng : lng)
            if CLLocationCoordinate2DIsValid(c) { meta.coordinate = c }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            meta.dateTaken = fmt.date(from: s)
        } else if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
                  let s = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            meta.dateTaken = fmt.date(from: s)
        }
        return meta
    }

    /// Decodes `url` at full resolution and writes a compressed 2048px JPEG (the "in-between" size
    /// stored in `photoFiles`, identical to import). Returns the written filename + pixel aspect
    /// ratio, or nil on failure. Safe to call off the main actor.
    nonisolated static func generateFullRes(from url: URL) -> (filename: String, aspect: Double)? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let decodeOpts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceSubsampleFactor: 1,
        ]
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, decodeOpts as CFDictionary),
              let full = compress(cg, maxDimension: 2048, quality: 0.82),
              let name = write(full, name: "\(UUID().uuidString)-0-full.jpg") else { return nil }
        let aspect = cg.height > 0 ? Double(cg.width) / Double(cg.height) : 0
        return (name, aspect)
    }

    /// Reads an image's pixel aspect ratio (width / height) from its header WITHOUT decoding
    /// the pixels — used to backfill `aspectRatio` on pins imported before that field existed.
    /// `nonisolated` so it can run off the main actor in a backfill task.
    nonisolated static func aspectRatio(ofImageAt url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, h > 0
        else { return nil }
        return w / h
    }

    // MARK: - Duplicate detection

    /// The result of scanning a project for duplicate photos: which pins to keep (one per
    /// duplicate cluster, the "original large" file) and which to remove (the compressed
    /// copies, e.g. "DSC02796 Large.jpeg"). `clusters` is the number of duplicate groups.
    struct DuplicatePlan {
        var remove: [PinnedLocationData] = []
        var clusters: Int = 0
    }

    /// Scans `pins` and clusters duplicates using TWO independent signals (a union of either
    /// match — so a missing one doesn't hide a real duplicate):
    ///  1. Normalized base filename — strips the extension and "large"/"copy"/"small" markers,
    ///     so `DSC02796 Large.jpeg` and `DSC02796.HIF` collapse to the same key `dsc02796`.
    ///  2. EXIF capture time (to the second) + GPS (±~10 m) — catches copies that were renamed
    ///     beyond recognition but came from the same shot. Requires BOTH a date and GPS so a
    ///     shared timestamp alone can never falsely group two distinct photos.
    ///
    /// Within each cluster it keeps the highest-scoring pin (see `keepScore` — original camera
    /// formats and non-"Large" names win) and marks the rest for removal. Read-only: it never
    /// mutates the pins; the caller decides what to do with `plan.remove`.
    static func findDuplicates(in pins: [PinnedLocationData]) -> DuplicatePlan {
        let live = pins.filter { $0.deletedAt == nil }
        guard live.count > 1 else { return DuplicatePlan() }

        // Union-Find over indices into `live`.
        var parent = Array(0..<live.count)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        // First index seen for each signature → union subsequent matches into it.
        var byName: [String: Int] = [:]
        var byMeta: [String: Int] = [:]
        for (i, pin) in live.enumerated() {
            let nameKey = normalizeName(pin.name)
            if !nameKey.isEmpty {
                if let j = byName[nameKey] { union(i, j) } else { byName[nameKey] = i }
            }
            if let d = pin.dateTaken, pin.hasGPS {
                let ts = Int(d.timeIntervalSinceReferenceDate)
                let metaKey = "\(ts)|\(String(format: "%.4f", pin.latitude))|\(String(format: "%.4f", pin.longitude))"
                if let j = byMeta[metaKey] { union(i, j) } else { byMeta[metaKey] = i }
            }
        }

        // Gather clusters.
        var clusters: [Int: [Int]] = [:]
        for i in live.indices { clusters[find(i), default: []].append(i) }

        var plan = DuplicatePlan()
        for (_, members) in clusters where members.count > 1 {
            plan.clusters += 1
            // Keep the best-scoring member; remove the rest.
            let sorted = members.sorted { keepScore(live[$0]) > keepScore(live[$1]) }
            for idx in sorted.dropFirst() { plan.remove.append(live[idx]) }
        }
        return plan
    }

    /// Strips the extension and common compressed-copy markers so derived files collapse to
    /// the same key as their original (e.g. `DSC02796 Large` → `dsc02796`).
    private static func normalizeName(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let exts = ["jpeg","jpg","heic","heif","hif","png","tif","tiff","arw","cr2","cr3","nef","dng","raw","orf","rw2"]
        for ext in exts where s.hasSuffix("." + ext) { s = String(s.dropLast(ext.count + 1)) }
        // Repeatedly peel trailing copy/size markers (e.g. "dsc1 large copy").
        let markers = [" large", "-large", "_large", " small", "-small", "_small", " copy", "-copy", "_copy"]
        var changed = true
        while changed {
            changed = false
            s = s.trimmingCharacters(in: .whitespaces)
            for m in markers where s.hasSuffix(m) {
                s = String(s.dropLast(m.count)); changed = true
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Higher = more likely the "original" the user wants to keep. The compressed copies
    /// (names containing "large"/"small"/"copy", JPEG exports) score low and get removed.
    private static func keepScore(_ pin: PinnedLocationData) -> Int {
        var score = 0
        let lname = pin.name.lowercased()
        if lname.contains("large") { score -= 1000 }
        if lname.contains("small") { score -= 1000 }
        if lname.contains("copy")  { score -= 500 }
        let ext = pin.originalFilePath.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let originalFormats: Set<String> = ["hif","heif","heic","raw","arw","cr2","cr3","nef","dng","tif","tiff","orf","rw2"]
        if originalFormats.contains(ext) { score += 200 }
        // Prefer pins whose original file is still on disk, and larger originals.
        if let p = pin.originalFilePath, FileManager.default.isReadableFile(atPath: p) {
            score += 50
            if let size = try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int {
                score += min(size / 1_000_000, 200)   // up to +200 by megabytes
            }
        }
        return score
    }
}

// MARK: - Model factory

extension PinnedLocationData {
    static func fromImport(
        context: NSManagedObjectContext,
        id: UUID = UUID(),
        name: String,
        coordinate: CLLocationCoordinate2D,
        hasGPS: Bool,
        dateTaken: Date?,
        originalFilePath: String,
        fullFilename: String,
        thumbFilename: String,
        sortOrder: Int,
        aspectRatio: Double = 0
    ) -> PinnedLocationData {
        let phantom = ScoutLocation(name: name, description: "", coordinate: coordinate, images: [])
        let pin = PinnedLocationData(context: context, from: phantom, sortOrder: sortOrder)
        pin.imageSourceRaw   = ScoutImage.ImageSource.imported.rawValue
        pin.photoFiles       = [fullFilename]
        pin.thumbnailFiles   = [thumbFilename]
        pin.originalFilePath = originalFilePath
        pin.originalFilename = URL(fileURLWithPath: originalFilePath).lastPathComponent
        pin.hasGPS           = hasGPS
        pin.dateTaken        = dateTaken
        pin.aspectRatio      = aspectRatio
        return pin
    }
}
