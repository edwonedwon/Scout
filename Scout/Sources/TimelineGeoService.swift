import Foundation
import CoreLocation
import ImageIO
import CoreData

// MARK: - Timeline JSON model

private struct TimelineEntry: Decodable {
    let startTime: Date
    let endTime: Date
    let visit: Visit?
    let activity: Activity?
    let timelinePath: [PathPoint]?

    struct Visit: Decodable {
        let topCandidate: TopCandidate?
        struct TopCandidate: Decodable {
            let placeLocation: String?   // "geo:lat,lng"
        }
    }
    struct Activity: Decodable {
        let start: String?   // "geo:lat,lng"
        let end: String?
    }
    /// A raw GPS trace point sampled during the segment. `durationMinutesOffsetFromStartTime`
    /// is minutes after `startTime`. These give accurate positions during movement — far
    /// better than interpolating a straight line between an activity's start and end.
    struct PathPoint: Decodable {
        let point: String?   // "geo:lat,lng"
        let durationMinutesOffsetFromStartTime: String?
    }
}

/// A single timed GPS fix, derived from timeline path points and activity endpoints.
private struct TimedFix {
    let time: Date
    let coord: CLLocationCoordinate2D
}

/// A stationary stay: the user was at `coord` for the whole [start, end] window.
private struct VisitWindow {
    let start: Date
    let end: Date
    let coord: CLLocationCoordinate2D
}

// MARK: - Service

/// Parses a Google Timeline JSON export and resolves GPS coordinates for timestamps.
@MainActor
enum TimelineGeoService {

    struct BackfillResult {
        var updated: Int = 0
        var skipped: Int = 0     // no dateTaken or no matching timeline window
        var failed: Int = 0      // matched but file write failed
        var detectedTimezone: String = ""
        var updatedPins: [PinnedLocationData] = []
    }

    // MARK: - Public entry point

    /// Loads the timeline JSON at `url`, then for every pin in `context` that has
    /// `hasGPS == false`, resolves the coordinate, writes GPS EXIF back to the photo
    /// file on disk (losslessly), and updates the SwiftData record.
    ///
    /// EXIF `DateTimeOriginal` has no timezone. We detect the timezone from the
    /// timeline entries' ISO 8601 offset and re-parse the EXIF date with that timezone
    /// so the timestamps match correctly — without this, e.g. a UTC system clock
    /// shifts all Japan photos 9 hours into the wrong activity windows.
    static func backfill(timelineURL: URL, context: NSManagedObjectContext,
                         onProgress: (@MainActor (Int, Int, String) -> Void)? = nil) async -> BackfillResult {
        let scoped = timelineURL.startAccessingSecurityScopedResource()
        defer { if scoped { timelineURL.stopAccessingSecurityScopedResource() } }
        guard let rawData = try? Data(contentsOf: timelineURL) else { return BackfillResult() }

        // Detect the timezone offset used in this timeline file (e.g. "+09:00" → JST).
        let detectedTZ = detectTimezone(from: rawData) ?? TimeZone.current
        let tzName = detectedTZ.identifier

        guard let entries = parseEntries(from: rawData) else { return BackfillResult() }

        let (visits, fixes) = buildIndex(entries)
        let exifFmt = makeDateFormatter(timezone: detectedTZ)

        let pins: [PinnedLocationData] = (try? context.fetch(FetchDescriptor<PinnedLocationData>())) ?? []
        // Candidates: photos with no GPS yet, OR photos whose GPS came from a *previous*
        // timeline backfill (so re-importing can correct them). Photos with GPS baked into
        // the original file are never touched.
        let candidates = pins.filter { (pin: PinnedLocationData) in !pin.hasGPS || pin.gpsFromTimeline }

        var result = BackfillResult(detectedTimezone: tzName)
        let total = candidates.count
        for (idx, pin) in candidates.enumerated() {
            await onProgress?(idx, total, pin.name)
            // Re-read EXIF date from the first photo file using the detected timezone.
            // This bypasses any timezone error baked into the stored dateTaken.
            let date = exifDate(from: pin, formatter: exifFmt) ?? pin.dateTaken
            guard let date else { result.skipped += 1; continue }
            guard let coord = coordinate(at: date, visits: visits, fixes: fixes) else { result.skipped += 1; continue }

            let fileCount = pin.photoFiles.count
            let writeOK = fileCount == 0 || pin.photoFiles.allSatisfy {
                writeGPS(coord, to: PinPhotoStore.fileURL($0))
            }

            if writeOK {
                pin.latitude        = coord.latitude
                pin.longitude       = coord.longitude
                pin.hasGPS          = true
                pin.gpsFromTimeline = true   // mark so a future re-import may correct it
                // Persist the corrected date too.
                if let corrected = exifDate(from: pin, formatter: exifFmt) {
                    pin.dateTaken = corrected
                }
                result.updated += 1
                result.updatedPins.append(pin)
            } else {
                result.failed += 1
            }
        }

        try? context.save()
        return result
    }

    // MARK: - EXIF date re-reading

    /// Reads `DateTimeOriginal` from the first photo file of a pin using the supplied
    /// formatter (which has the correct timezone baked in).
    private static func exifDate(from pin: PinnedLocationData, formatter: DateFormatter) -> Date? {
        guard let filename = pin.photoFiles.first else { return nil }
        let url = PinPhotoStore.fileURL(filename)
        guard let data   = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let str  = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            return formatter.date(from: str)
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let str  = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
            return formatter.date(from: str)
        }
        return nil
    }

    private static func makeDateFormatter(timezone: TimeZone) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.timeZone = timezone
        return fmt
    }

    // MARK: - Timezone detection

    /// Extracts the UTC offset from the first recognisable timestamp in the raw JSON bytes
    /// (e.g. `"2026-06-12T07:41:58.856+09:00"` → `TimeZone(secondsFromGMT: 32400)`).
    private static func detectTimezone(from data: Data) -> TimeZone? {
        // Scan the first ~2 KB for a recognisable ISO 8601 timestamp with offset.
        let sample = String(decoding: data.prefix(2048), as: UTF8.self)
        // Match e.g. +09:00 or -05:30
        let pattern = #"[+-]\d{2}:\d{2}""#
        guard let range = sample.range(of: pattern, options: .regularExpression),
              let offset = parseOffsetSeconds(String(sample[range].dropLast())) else { return nil }
        return TimeZone(secondsFromGMT: offset)
    }

    private static func parseOffsetSeconds(_ str: String) -> Int? {
        // str looks like "+09:00" or "-05:30"
        guard str.count == 6 else { return nil }
        let sign:  Int = str.hasPrefix("-") ? -1 : 1
        let parts = str.dropFirst().split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]),
              let m = Int(parts[1]) else { return nil }
        return sign * (h * 3600 + m * 60)
    }

    // MARK: - Timeline index

    /// Splits the timeline into stationary visit windows and a time-sorted list of GPS
    /// fixes. Visits cover stays fully; the fix list (dense `timelinePath` points plus
    /// activity endpoints) covers movement.
    private static func buildIndex(_ entries: [TimelineEntry]) -> (visits: [VisitWindow], fixes: [TimedFix]) {
        var visits: [VisitWindow] = []
        var fixes: [TimedFix] = []
        for e in entries {
            if let loc = e.visit?.topCandidate?.placeLocation, let c = parseGeo(loc) {
                visits.append(VisitWindow(start: e.startTime, end: e.endTime, coord: c))
            }
            if let a = e.activity {
                if let c = a.start.flatMap(parseGeo) { fixes.append(TimedFix(time: e.startTime, coord: c)) }
                if let c = a.end.flatMap(parseGeo)   { fixes.append(TimedFix(time: e.endTime,   coord: c)) }
            }
            if let path = e.timelinePath {
                for p in path {
                    guard let c = p.point.flatMap(parseGeo),
                          let offStr = p.durationMinutesOffsetFromStartTime,
                          let off = Double(offStr) else { continue }
                    fixes.append(TimedFix(time: e.startTime.addingTimeInterval(off * 60), coord: c))
                }
            }
        }
        fixes.sort { $0.time < $1.time }
        visits.sort { $0.start < $1.start }
        return (visits, fixes)
    }

    // MARK: - Coordinate resolution

    // A photo taken during a stay → the place. During movement → interpolate between the
    // two nearest GPS fixes if they're close in time, else snap to the nearest fix. If the
    // nearest fix is too far away in time (a real GPS gap), return nil rather than smear the
    // photo onto a straight line across the gap (which produced the diagonal-line artifact).
    private static let maxInterpolationGap: TimeInterval = 30 * 60
    private static let maxSnapDistance: TimeInterval = 20 * 60

    private static func coordinate(at date: Date,
                                   visits: [VisitWindow],
                                   fixes: [TimedFix]) -> CLLocationCoordinate2D? {
        // 1. Stationary visit window wins — the user wasn't moving.
        for v in visits where date >= v.start && date <= v.end { return v.coord }

        guard !fixes.isEmpty else { return nil }

        // 2. Binary search for the first fix at/after `date`.
        var lo = 0, hi = fixes.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if fixes[mid].time < date { lo = mid + 1 } else { hi = mid }
        }
        let after  = lo < fixes.count ? fixes[lo] : nil
        let before = lo > 0 ? fixes[lo - 1] : nil

        if let a = before, let b = after {
            if b.time == a.time { return a.coord }
            let gap = b.time.timeIntervalSince(a.time)
            if gap <= maxInterpolationGap {
                let f = date.timeIntervalSince(a.time) / gap
                return CLLocationCoordinate2D(
                    latitude:  a.coord.latitude  + (b.coord.latitude  - a.coord.latitude)  * f,
                    longitude: a.coord.longitude + (b.coord.longitude - a.coord.longitude) * f
                )
            }
            let da = date.timeIntervalSince(a.time)
            let db = b.time.timeIntervalSince(date)
            if min(da, db) <= maxSnapDistance { return da < db ? a.coord : b.coord }
            return nil
        }
        if let a = before, date.timeIntervalSince(a.time) <= maxSnapDistance { return a.coord }
        if let b = after,  b.time.timeIntervalSince(date) <= maxSnapDistance { return b.coord }
        return nil
    }

    private static func parseGeo(_ string: String) -> CLLocationCoordinate2D? {
        guard string.hasPrefix("geo:") else { return nil }
        let parts = string.dropFirst(4).split(separator: ",")
        guard parts.count == 2,
              let lat = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let lng = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(coord) ? coord : nil
    }

    // MARK: - JSON loading

    private static func parseEntries(from data: Data) -> [TimelineEntry]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            let fmts: [ISO8601DateFormatter] = [
                { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }(),
                { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }(),
            ]
            for fmt in fmts { if let d = fmt.date(from: str) { return d } }
            throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(),
                                                   debugDescription: "Unrecognised date: \(str)")
        }
        return try? decoder.decode([TimelineEntry].self, from: data)
    }

    // MARK: - Lossless EXIF GPS writing

    /// Writes GPS coordinates into the image file at `url` losslessly (no pixel re-encoding).
    @discardableResult
    static func writeGPS(_ coord: CLLocationCoordinate2D, to url: URL) -> Bool {
        guard let data   = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type   = CGImageSourceGetType(source) else { return false }

        let meta = CGImageMetadataCreateMutable()
        let items: [(CFString, CFString, Any)] = [
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude,     NSNumber(value: abs(coord.latitude))),
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitudeRef,  (coord.latitude  >= 0 ? "N" : "S") as CFString),
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude,    NSNumber(value: abs(coord.longitude))),
            (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitudeRef, (coord.longitude >= 0 ? "E" : "W") as CFString),
        ]
        for (dict, key, value) in items {
            CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, value as CFTypeRef)
        }

        let tmp = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else { return false }
        let options: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: true]
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) else { return false }

        return (try? FileManager.default.replaceItemAt(url, withItemAt: tmp)) != nil
    }
}
