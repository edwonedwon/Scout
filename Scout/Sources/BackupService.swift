import Foundation
import CoreData
import CoreLocation
import ScoutKit
#if os(macOS)
import ZIPFoundation
#endif

// MARK: - Backup manifest (Codable mirror of the SwiftData models)

struct BackupManifest: Codable {
    var version: Int = 1
    var exportedAt: Date
    var projects: [BackupProject] = []
    var standaloneLists: [BackupList] = []   // lists with no project
    var unfiledPins: [BackupPin] = []        // pins with no list and no project
}

struct BackupProject: Codable {
    var uuid: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var lists: [BackupList]
    var importedPhotos: [BackupPin]
    /// Imported `.fountain` scripts + their scene→list links. Optional so older backups
    /// (written before scripts existed) still decode.
    var scripts: [BackupScript]? = nil
}

struct BackupScript: Codable {
    var uuid: UUID
    var name: String
    var rawText: String
    var importedAt: Date
    var updatedAt: Date
    var sortOrder: Int
    var highlights: [BackupScriptHighlight]
}

struct BackupScriptHighlight: Codable {
    var uuid: UUID
    var rangeStart: Int
    var rangeLength: Int
    var excerpt: String
    var contextBefore: String
    var contextAfter: String
    var sceneHeading: String?
    var createdAt: Date
    /// The uuid of the list this scene is linked to (re-mapped to the freshly imported list).
    var listUUID: UUID?
}

struct BackupList: Codable {
    var uuid: UUID
    var name: String
    var colorHex: String
    var createdAt: Date
    var sortOrder: Int
    var panelOrder: Int
    var pins: [BackupPin]
    /// Optional fields (added later — nil when decoding older backups).
    var sceneType: String? = nil
    var deletedAt: Date? = nil
    /// Nested child lists (folders), recursively. Older backups omit this (flat).
    var childLists: [BackupList]? = nil
}

struct BackupPin: Codable {
    var uuid: UUID
    var name: String
    var notes: String
    var latitude: Double
    var longitude: Double
    var statusRaw: String
    var createdAt: Date
    var sortOrder: Int
    var panelOrder: Int
    var imageSourceRaw: String?
    var photoFiles: [String]
    var thumbnailFiles: [String]
    /// Last path component of the original large file. Full path is NOT stored so
    /// the backup is portable; use relinkOriginals(folder:context:) to restore it.
    var originalFileBasename: String?
    var hasGPS: Bool
    var gpsFromTimeline: Bool
    var dateTaken: Date?
    var googlePlaceId: String?
    var sourceURLString: String?
    var googleMapsURLString: String?
    var imageURL: String?
    /// Trash state — preserved so importing is lossless (older backups omit it → nil = not trashed).
    var deletedAt: Date? = nil
    // The following are defaulted so OLDER backups (which omit them) still decode cleanly.
    // They carry user-set state that must survive an export→import round-trip — a missing field
    // here is exactly how flags/rotation got silently dropped before. Keep every user-mutable
    // attribute on PinnedLocationData represented in this struct.
    /// Flag/star state.
    var isFlagged: Bool = false
    /// User photo rotation in CCW 90° steps.
    var rotationQuarterTurns: Int = 0
    /// Known display aspect ratio (width/height of the raw bitmap), 0 = not yet measured.
    var aspectRatio: Double = 0
    /// Device-independent original-file name (syncs via iCloud); pairs with relinkOriginals.
    var originalFilename: String? = nil
}

// MARK: - Service

@MainActor
enum BackupService {

    // MARK: - Export

    /// Exports a single project to a zip archive and returns the temp URL.
    static func export(project: ProjectData) async throws -> URL {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ScoutBackup-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let photosDir = tmp.appendingPathComponent("photos", isDirectory: true)
        try fm.createDirectory(at: photosDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // --- Collect all pins for this project (recursing nested lists) ---
        func descendants(_ list: LocationListData) -> [LocationListData] {
            [list] + list.childLists.flatMap(descendants)
        }
        let topLevelLists = project.lists.filter { $0.parentList == nil }
        let everyList = topLevelLists.flatMap(descendants)
        let allPins = everyList.flatMap(\.pins) + project.importedPhotos

        // --- Copy derivative files: thumbnails (300px) AND full-res (2048px) ---
        // Both are included so a restore is complete (full-res viewing works without a relink).
        // Original camera files (originalFilePath) are intentionally NOT exported — they're large
        // and recoverable via relinkOriginals(folder:).
        var copiedFiles: Set<String> = []
        for pin in allPins {
            for f in (pin.thumbnailFiles + pin.photoFiles) where !copiedFiles.contains(f) {
                let src = PinPhotoStore.fileURL(f)
                if fm.fileExists(atPath: src.path) {
                    try? fm.copyItem(at: src, to: photosDir.appendingPathComponent(f))
                }
                copiedFiles.insert(f)
            }
        }

        // --- Build manifest with just this project ---
        var manifest = BackupManifest(exportedAt: Date())
        var bp = BackupProject(
            uuid: project.uuid,
            name: project.name,
            notes: project.notes,
            createdAt: project.createdAt,
            lists: [],
            importedPhotos: []
        )
        // Only top-level lists here; backupList recurses childLists so the hierarchy is preserved
        // and each list is written exactly once.
        for list in topLevelLists.sorted(by: { $0.panelOrder < $1.panelOrder }) {
            bp.lists.append(backupList(list))
        }
        for pin in project.importedPhotos.sorted(by: { $0.panelOrder < $1.panelOrder }) {
            bp.importedPhotos.append(backupPin(pin))
        }
        bp.scripts = project.scripts.sorted(by: { $0.sortOrder < $1.sortOrder }).map(backupScript)
        manifest.projects.append(bp)

        // --- Write JSON ---
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try enc.encode(manifest)
        try json.write(to: tmp.appendingPathComponent("backup.json"))

        // --- Zip ---
        let safeName = project.name.replacingOccurrences(of: "/", with: "-")
        let destZip = fm.temporaryDirectory.appendingPathComponent("Scout-\(safeName)-\(dateStamp()).zip")
        try? fm.removeItem(at: destZip)
        try zip(sourceDir: tmp, to: destZip)
        return destZip
    }

    // MARK: - Import

    struct ImportSummary {
        var projectsAdded: Int = 0
        var listsAdded: Int = 0
        var pinsAdded: Int = 0
        var scriptsAdded: Int = 0
        var photoFilesCopied: Int = 0
        var skippedDuplicates: Int = 0
    }

    /// Unzips a backup archive and merges its contents into `context`.
    /// Imports a backup zip as a brand-new project. If a project with the same name already
    /// exists, appends " 2", " 3", etc. All UUIDs are regenerated so there are never conflicts.
    static func importBackup(from url: URL, context: NSManagedObjectContext) async throws -> ImportSummary {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ScoutRestore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        try unzip(archive: url, to: tmp)

        let jsonURL = tmp.appendingPathComponent("backup.json")
        let data = try Data(contentsOf: jsonURL)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let manifest = try dec.decode(BackupManifest.self, from: data)

        var summary = ImportSummary()
        let photosDir = tmp.appendingPathComponent("photos")

        // Existing project names for collision detection. Mutable: each name handed out is
        // reserved back into the set so that two same-named projects within ONE import (or a
        // base that already exists) each get a distinct suffix instead of colliding again.
        // Only LIVE projects count for collision detection — trashed names must not leak into
        // this live interaction (else importing after trashing a "Foo (1)" would jump to "(2)").
        let existingProjects: [ProjectData] = (try? context.fetch(FetchDescriptor(ProjectData.self))) ?? []
        var existingNames = Set(existingProjects.filter { $0.deletedAt == nil }.map(\.name))

        // TEMP INSTRUMENTATION — diagnose "existing project gets renamed on import" report.
        // Logs every naming decision to ~/Library/Application Support/Scout/import-debug.log.
        func debugLog(_ s: String) {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scout", isDirectory: true)
            let url = dir.appendingPathComponent("import-debug.log")
            let line = "\(ISO8601DateFormatter().string(from: Date()))  \(s)\n"
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: url)
            }
        }
        debugLog("=== IMPORT START ===")
        for p in existingProjects {
            debugLog("EXISTING project: name=\(p.name.debugDescription) uuid=\(p.uuid) deletedAt=\(String(describing: p.deletedAt))")
        }
        debugLog("LIVE existingNames seed = \(existingNames.sorted())")

        func uniqueName(_ base: String) -> String {
            let chosen: String
            if existingNames.contains(base) {
                var n = 1
                while existingNames.contains("\(base) (\(n))") { n += 1 }
                chosen = "\(base) (\(n))"
            } else {
                chosen = base
            }
            existingNames.insert(chosen)   // reserve so the next call won't reuse it
            debugLog("uniqueName(base=\(base.debugDescription)) -> chosen=\(chosen.debugDescription)")
            return chosen
        }

        func copyPhotos(_ files: [String]) {
            for f in files {
                let src = photosDir.appendingPathComponent(f)
                let dst = PinPhotoStore.fileURL(f)
                if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                    summary.photoFilesCopied += 1
                }
            }
        }

        func insertPin(_ bp: BackupPin, list: LocationListData?, project: ProjectData?) {
            // Always use a fresh UUID so re-importing the same backup creates a new copy.
            var fresh = bp; fresh.uuid = UUID()
            copyPhotos(fresh.photoFiles + fresh.thumbnailFiles)
            let pin = PinnedLocationData.fromBackup(fresh, context: context)
            if let list {
                pin.list = list
            } else if let project {
                // Setting the inverse populates project.importedPhotos (a computed relationship
                // array — appending to its getter result would be a no-op).
                pin.owningProject = project
            }
            summary.pinsAdded += 1
        }

        // Original backup list-uuid → freshly created list, so script scene-links can be re-tied.
        var listsByOriginalUUID: [UUID: LocationListData] = [:]

        @discardableResult
        func insertList(_ bl: BackupList, project: ProjectData?, parent: LocationListData? = nil) -> LocationListData {
            var fresh = bl; fresh.uuid = UUID()
            let list = LocationListData.fromBackup(fresh, context: context)
            list.project = project
            list.parentList = parent
            listsByOriginalUUID[bl.uuid] = list
            summary.listsAdded += 1
            for bp in bl.pins { insertPin(bp, list: list, project: nil) }
            // Recurse nested folders, chaining each child to this list.
            for child in (bl.childLists ?? []) { insertList(child, project: project, parent: list) }
            return list
        }

        func insertScript(_ bs: BackupScript, project: ProjectData) {
            let script = ScriptData(context: context, name: bs.name, rawText: bs.rawText, sortOrder: bs.sortOrder)
            script.importedAt = bs.importedAt
            script.updatedAt = bs.updatedAt
            script.project = project
            summary.scriptsAdded += 1
            for bh in bs.highlights {
                // Only re-create links whose list made it into the import (skip orphans).
                guard let listUUID = bh.listUUID, let list = listsByOriginalUUID[listUUID] else { continue }
                let h = ScriptHighlight(context: context, rangeStart: bh.rangeStart, rangeLength: bh.rangeLength,
                                        excerpt: bh.excerpt, contextBefore: bh.contextBefore,
                                        contextAfter: bh.contextAfter, sceneHeading: bh.sceneHeading)
                h.script = script
                h.list = list
            }
        }

        for bp in manifest.projects {
            var fresh = bp; fresh.uuid = UUID()
            fresh.name = uniqueName(bp.name)
            let project = ProjectData.fromBackup(fresh, context: context)
            debugLog("CREATED new project: name=\(project.name.debugDescription) uuid=\(project.uuid) (from backup name=\(bp.name.debugDescription))")
            summary.projectsAdded += 1
            for bl in bp.lists           { _ = insertList(bl, project: project) }
            for pin in bp.importedPhotos { insertPin(pin, list: nil, project: project) }
            for bs in bp.scripts ?? []   { insertScript(bs, project: project) }
        }

        // Standalone lists and unfiled pins (edge cases — wrap in a project named after the file)
        if !manifest.standaloneLists.isEmpty || !manifest.unfiledPins.isEmpty {
            let wrapperName = uniqueName("Imported")
            let wrapper = ProjectData(context: context, name: wrapperName, notes: "")
            summary.projectsAdded += 1
            for bl in manifest.standaloneLists { _ = insertList(bl, project: wrapper) }
            for bp in manifest.unfiledPins     { insertPin(bp, list: nil, project: wrapper) }
        }

        try? context.save()
        return summary
    }

    // MARK: - Relink original files

    struct RelinkSummary {
        /// Pins newly matched to an original file this run.
        var linked: Int = 0
        /// Pins we couldn't confidently match to any file in the folder.
        var notFound: Int = 0
        /// Pins skipped because they already had both an original reference and a full-res image.
        var alreadyLinked: Int = 0
        /// Compressed 2048px "in-between" images generated from originals this run.
        var photosGenerated: Int = 0
        /// Total candidate image files found in the chosen folder (recursively).
        var scanned: Int = 0
    }

    /// Recovers the link between each pin and its original photo file, then rebuilds the compressed
    /// 2048px image that the carousel and Core Data sync rely on.
    ///
    /// Matching is multi-signal for accuracy — a pin is only linked when several pieces of data
    /// agree: the **filename** (e.g. pin "DSC02453" ↔ "DSC02453.HIF"), the **EXIF capture date**
    /// (±2 s), and the **GPS coordinate** (±15 m). Acceptance requires a name match corroborated by
    /// date or GPS, or a date+GPS match for files renamed beyond recognition. Camera-original
    /// formats (HIF/RAW) win ties over JPEG exports.
    ///
    /// On a match it stores the device-independent **filename** (`originalFilename`, which syncs via
    /// iCloud) plus the local absolute path (`originalFilePath`, a this-Mac convenience), and
    /// regenerates the compressed `photoFiles` image so full-resolution viewing and sync work again.
    ///
    /// The heavy folder scan, metadata reads and image compression run off the main actor; only the
    /// final managed-object writes happen on the context's queue. `progress` is called with a stage
    /// description and a 0–1 fraction; it may fire from a background thread.
    static func relinkOriginals(folder: URL,
                                context: NSManagedObjectContext,
                                progress: (@Sendable (String, Double) -> Void)? = nil) async -> RelinkSummary {
        // --- Snapshot the pins that still need work (main/context thread, value types only) ---
        let allPins: [PinnedLocationData] = (try? context.fetch(FetchDescriptor(PinnedLocationData.self))) ?? []
        var objectIDs: [NSManagedObjectID] = []
        var infos: [RelinkPinInfo] = []
        var alreadyLinked = 0
        for pin in allPins {
            let needsFullRes = pin.photoFiles.isEmpty
            let needsName    = (pin.originalFilename ?? "").isEmpty
            guard needsFullRes || needsName else { alreadyLinked += 1; continue }
            infos.append(RelinkPinInfo(idx: infos.count, name: pin.name, dateTaken: pin.dateTaken,
                                       lat: pin.latitude, lng: pin.longitude, hasGPS: pin.hasGPS,
                                       needsFullRes: needsFullRes))
            objectIDs.append(pin.objectID)
        }

        // --- Off-main: scan, read metadata, match, and compress originals ---
        let captured = infos
        let outcome = await Task.detached(priority: .userInitiated) {
            RelinkMatcher.run(folder: folder, pins: captured, progress: progress)
        }.value

        // --- Apply results on the context's queue ---
        var summary = RelinkSummary()
        summary.scanned       = outcome.scanned
        summary.notFound      = outcome.notFound
        summary.alreadyLinked = alreadyLinked
        for r in outcome.results {
            guard r.idx < objectIDs.count,
                  let pin = context.object(with: objectIDs[r.idx]) as? PinnedLocationData else { continue }
            pin.originalFilename = r.originalFilename
            pin.originalFilePath = r.originalPath
            if pin.aspectRatio == 0, r.aspect > 0 { pin.aspectRatio = r.aspect }
            if let full = r.fullResName { pin.photoFiles = [full]; summary.photosGenerated += 1 }
            summary.linked += 1
        }
        try? context.save()
        progress?("Done", 1.0)
        return summary
    }

    // MARK: - Helpers

    private static func backupPin(_ pin: PinnedLocationData) -> BackupPin {
        // Both thumbnails (300px) and full-res (2048px) derivatives are exported so a restore is
        // complete. Original camera files are not (recoverable via relinkOriginals).
        BackupPin(
            uuid: pin.uuid,
            name: pin.name,
            notes: pin.notes,
            latitude: pin.latitude,
            longitude: pin.longitude,
            statusRaw: pin.statusRaw,
            createdAt: pin.createdAt,
            sortOrder: pin.sortOrder,
            panelOrder: pin.panelOrder,
            imageSourceRaw: pin.imageSourceRaw,
            photoFiles: pin.photoFiles,
            thumbnailFiles: pin.thumbnailFiles,
            originalFileBasename: pin.originalFilePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            hasGPS: pin.hasGPS,
            gpsFromTimeline: pin.gpsFromTimeline,
            dateTaken: pin.dateTaken,
            googlePlaceId: pin.googlePlaceId,
            sourceURLString: pin.sourceURLString,
            googleMapsURLString: pin.googleMapsURLString,
            imageURL: pin.imageURL,
            deletedAt: pin.deletedAt,
            isFlagged: pin.isFlagged,
            rotationQuarterTurns: pin.rotationQuarterTurns,
            aspectRatio: pin.aspectRatio,
            originalFilename: pin.originalFilename
        )
    }

    private static func backupList(_ list: LocationListData) -> BackupList {
        BackupList(
            uuid: list.uuid,
            name: list.name,
            colorHex: list.colorHex,
            createdAt: list.createdAt,
            sortOrder: list.sortOrder,
            panelOrder: list.panelOrder,
            pins: list.pins.sorted(by: { $0.sortOrder < $1.sortOrder }).map(backupPin),
            sceneType: list.sceneType,
            deletedAt: list.deletedAt,
            // Recurse nested folders so the full hierarchy is preserved.
            childLists: list.childLists.sorted(by: { $0.panelOrder < $1.panelOrder }).map(backupList)
        )
    }

    private static func backupScript(_ script: ScriptData) -> BackupScript {
        BackupScript(
            uuid: script.uuid,
            name: script.name,
            rawText: script.rawText,
            importedAt: script.importedAt,
            updatedAt: script.updatedAt,
            sortOrder: script.sortOrder,
            highlights: script.highlights.map { h in
                BackupScriptHighlight(
                    uuid: h.uuid,
                    rangeStart: h.rangeStart,
                    rangeLength: h.rangeLength,
                    excerpt: h.excerpt,
                    contextBefore: h.contextBefore,
                    contextAfter: h.contextAfter,
                    sceneHeading: h.sceneHeading,
                    createdAt: h.createdAt,
                    listUUID: h.list?.uuid
                )
            }
        )
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: Date())
    }

    // MARK: - Zip / unzip via ZIPFoundation (sandbox-safe)

    #if os(macOS)
    private static func zip(sourceDir: URL, to dest: URL) throws {
        let archive = try Archive(url: dest, accessMode: .create)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil) else {
            throw BackupError.zipFailed(0)
        }
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            guard !isDir.boolValue else { continue }
            let relative = fileURL.path.replacingOccurrences(of: sourceDir.path + "/", with: "")
            try archive.addEntry(with: relative, fileURL: fileURL)
        }
    }

    private static func unzip(archive url: URL, to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: url, to: dest)
    }
    #else
    private static func zip(sourceDir: URL, to dest: URL) throws {
        throw BackupError.unsupportedOnPlatform
    }
    private static func unzip(archive: URL, to dest: URL) throws {
        throw BackupError.unsupportedOnPlatform
    }
    #endif
}

// MARK: - Model factory extensions

extension PinnedLocationData {
    static func fromBackup(_ b: BackupPin, context: NSManagedObjectContext) -> PinnedLocationData {
        let coord = CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)
        let loc = ScoutLocation(id: b.uuid, name: b.name, description: b.notes,
                                coordinate: coord, images: [])
        let pin = PinnedLocationData(context: context, from: loc, sortOrder: b.sortOrder)
        pin.uuid             = b.uuid
        pin.notes            = b.notes
        pin.statusRaw        = b.statusRaw
        pin.createdAt        = b.createdAt
        pin.panelOrder       = b.panelOrder
        pin.imageSourceRaw   = b.imageSourceRaw
        pin.photoFiles       = b.photoFiles
        pin.thumbnailFiles   = b.thumbnailFiles
        pin.hasGPS           = b.hasGPS
        pin.gpsFromTimeline  = b.gpsFromTimeline
        pin.dateTaken        = b.dateTaken
        pin.googlePlaceId    = b.googlePlaceId
        pin.sourceURLString  = b.sourceURLString
        pin.googleMapsURLString = b.googleMapsURLString
        pin.imageURL         = b.imageURL
        pin.deletedAt        = b.deletedAt
        pin.isFlagged        = b.isFlagged
        pin.rotationQuarterTurns = b.rotationQuarterTurns
        pin.aspectRatio      = b.aspectRatio
        pin.originalFilename = b.originalFilename
        // originalFilePath is left nil (machine-specific) — user relinks after import; the
        // device-independent originalFilename above lets relink rematch without rescanning names.
        return pin
    }
}

extension LocationListData {
    static func fromBackup(_ b: BackupList, context: NSManagedObjectContext) -> LocationListData {
        let list = LocationListData(context: context, name: b.name, colorHex: b.colorHex)
        list.uuid       = b.uuid
        list.createdAt  = b.createdAt
        list.sortOrder  = b.sortOrder
        list.panelOrder = b.panelOrder
        list.sceneType  = b.sceneType
        list.deletedAt  = b.deletedAt
        return list
    }
}

extension ProjectData {
    static func fromBackup(_ b: BackupProject, context: NSManagedObjectContext) -> ProjectData {
        let p = ProjectData(context: context, name: b.name, notes: b.notes)
        p.uuid      = b.uuid
        p.createdAt = b.createdAt
        return p
    }
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case zipFailed(Int32)
    case unzipFailed(Int32)
    case unsupportedOnPlatform

    var errorDescription: String? {
        switch self {
        case .zipFailed(let code):   return "zip exited with code \(code)"
        case .unzipFailed(let code): return "unzip exited with code \(code)"
        case .unsupportedOnPlatform: return "Backup import/export isn't available on this platform yet."
        }
    }
}

// MARK: - Relink matching (off-main; value types only so it crosses the actor boundary safely)

/// A pin's match-relevant data, snapshotted from the managed object on the context's queue.
private struct RelinkPinInfo: Sendable {
    let idx: Int
    let name: String
    let dateTaken: Date?
    let lat: Double
    let lng: Double
    let hasGPS: Bool
    /// True when the pin has no compressed full-res image yet and one should be generated.
    let needsFullRes: Bool
}

/// The outcome for one matched pin, applied back to the managed object on the context's queue.
private struct RelinkResult: Sendable {
    let idx: Int
    let originalFilename: String
    let originalPath: String
    let aspect: Double          // 0 when unknown
    let fullResName: String?    // newly generated 2048px file, if one was made
}

private enum RelinkMatcher {
    struct Outcome: Sendable {
        var results: [RelinkResult] = []
        var scanned: Int = 0
        var notFound: Int = 0
    }

    /// Strips the extension and "large/small/copy" markers so a derived/export name collapses to
    /// the same key as its camera original (e.g. "DSC02796 Large.jpeg" → "dsc02796").
    static func normalize(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for ext in PhotoImportService.originalExtensions where s.hasSuffix("." + ext) {
            s = String(s.dropLast(ext.count + 1))
        }
        let markers = [" large","-large","_large"," small","-small","_small"," copy","-copy","_copy"]
        var changed = true
        while changed {
            changed = false
            s = s.trimmingCharacters(in: .whitespaces)
            for m in markers where s.hasSuffix(m) { s = String(s.dropLast(m.count)); changed = true }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Higher rank = more likely a camera original (preferred over JPEG exports in a tie).
    static func formatRank(_ ext: String) -> Int {
        let originals: Set<String> = ["hif","heif","heic","arw","cr2","cr3","nef","dng","tif","tiff","orf","rw2","raw"]
        if originals.contains(ext) { return 2 }
        if ext == "jpg" || ext == "jpeg" { return 1 }
        return 0
    }

    /// Approximate planar distance in meters between two coordinates (fine at photo scale).
    static func meters(_ aLat: Double, _ aLng: Double, _ bLat: Double, _ bLng: Double) -> Double {
        let dLat = (bLat - aLat) * 111_000
        let dLng = (bLng - aLng) * 111_000 * cos(aLat * .pi / 180)
        return (dLat * dLat + dLng * dLng).squareRoot()
    }

    static func run(folder: URL,
                    pins: [RelinkPinInfo],
                    progress: (@Sendable (String, Double) -> Void)?) -> Outcome {
        let fm = FileManager.default
        progress?("Scanning folder…", 0.02)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        // 1. Recursively collect candidate image files (the enumerator descends all sub-folders).
        var urls: [URL] = []
        if let en = fm.enumerator(at: folder,
                                  includingPropertiesForKeys: [.isRegularFileKey],
                                  options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if PhotoImportService.originalExtensions.contains(u.pathExtension.lowercased()) { urls.append(u) }
            }
        }
        var out = Outcome()
        out.scanned = urls.count

        // 2. Read header metadata (filename + date + GPS + aspect) for every candidate.
        var metas: [PhotoImportService.OriginalMeta] = []
        metas.reserveCapacity(urls.count)
        for (i, u) in urls.enumerated() {
            if i % 50 == 0 {
                progress?("Reading photo metadata… (\(i)/\(urls.count))",
                          0.05 + 0.25 * Double(i) / Double(max(urls.count, 1)))
            }
            metas.append(PhotoImportService.readOriginalMeta(at: u))
        }

        // 3. Index by normalized filename for fast primary matching.
        var byName: [String: [Int]] = [:]
        for (i, m) in metas.enumerated() { byName[normalize(m.filename), default: []].append(i) }

        // 4. Match each pin against the candidates using aligned signals.
        progress?("Matching originals…", 0.32)
        var matched: [(pin: RelinkPinInfo, mi: Int)] = []
        for pin in pins {
            var best: (score: Int, rank: Int, mi: Int)? = nil
            func consider(_ mi: Int, nameMatch: Bool) {
                let m = metas[mi]
                var dateMatch = false
                if let pd = pin.dateTaken, let md = m.dateTaken, abs(pd.timeIntervalSince(md)) <= 2 { dateMatch = true }
                var gpsMatch = false
                if pin.hasGPS, let mc = m.coordinate,
                   meters(pin.lat, pin.lng, mc.latitude, mc.longitude) <= 15 { gpsMatch = true }
                // Require multiple signals to agree: name + (date or GPS), or date + GPS.
                guard (nameMatch && (dateMatch || gpsMatch)) || (dateMatch && gpsMatch) else { return }
                let score = (nameMatch ? 3 : 0) + (dateMatch ? 3 : 0) + (gpsMatch ? 2 : 0)
                let rank = formatRank(m.ext)
                if best == nil || score > best!.score || (score == best!.score && rank > best!.rank) {
                    best = (score, rank, mi)
                }
            }
            for mi in byName[normalize(pin.name)] ?? [] { consider(mi, nameMatch: true) }
            if best == nil {                       // renamed file: fall back to date+GPS over all
                for mi in metas.indices { consider(mi, nameMatch: false) }
            }
            if let b = best { matched.append((pin, b.mi)) } else { out.notFound += 1 }
        }

        // 5. Generate the compressed 2048px image for matched pins that need one.
        let genTotal = matched.filter { $0.pin.needsFullRes }.count
        var genDone = 0
        for (pin, mi) in matched {
            let m = metas[mi]
            var fullName: String? = nil
            var aspect = m.aspect ?? 0
            if pin.needsFullRes {
                progress?("Generating compressed images… (\(genDone + 1)/\(genTotal))",
                          0.4 + 0.55 * Double(genDone) / Double(max(genTotal, 1)))
                if let g = PhotoImportService.generateFullRes(from: m.url) {
                    fullName = g.filename
                    if g.aspect > 0 { aspect = g.aspect }
                }
                genDone += 1
            }
            out.results.append(RelinkResult(idx: pin.idx, originalFilename: m.filename,
                                            originalPath: m.url.path, aspect: aspect, fullResName: fullName))
        }
        progress?("Saving…", 0.97)
        return out
    }
}
