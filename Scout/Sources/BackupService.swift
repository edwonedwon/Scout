import Foundation
import SwiftData
import CoreLocation
import ScoutKit

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

        // --- Copy thumbnail files only (not full-res photoFiles) ---
        // Full-res photoFiles are 2048px JPEGs that dominate export size.
        // Thumbnails (300px) are sufficient for the app to run after restore;
        // carousel falls back to thumbnails until the user relinks originals.
        var copiedFiles: Set<String> = []
        for pin in allPins {
            for f in pin.thumbnailFiles where !copiedFiles.contains(f) {
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
    static func importBackup(from url: URL, context: ModelContext) async throws -> ImportSummary {
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

        // Existing project names for collision detection.
        let existingNames = Set((try? context.fetch(FetchDescriptor<ProjectData>()))?.map(\.name) ?? [])

        func uniqueName(_ base: String) -> String {
            guard existingNames.contains(base) else { return base }
            var n = 2
            while existingNames.contains("\(base) \(n)") { n += 1 }
            return "\(base) \(n)"
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
            let pin = PinnedLocationData.fromBackup(fresh)
            context.insert(pin)
            if let list {
                pin.list = list
            } else if let project {
                pin.owningProject = project
                project.importedPhotos.append(pin)
            }
            summary.pinsAdded += 1
        }

        // Original backup list-uuid → freshly created list, so script scene-links can be re-tied.
        var listsByOriginalUUID: [UUID: LocationListData] = [:]

        @discardableResult
        func insertList(_ bl: BackupList, project: ProjectData?, parent: LocationListData? = nil) -> LocationListData {
            var fresh = bl; fresh.uuid = UUID()
            let list = LocationListData.fromBackup(fresh)
            context.insert(list)
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
            let script = ScriptData(name: bs.name, rawText: bs.rawText, sortOrder: bs.sortOrder)
            script.importedAt = bs.importedAt
            script.updatedAt = bs.updatedAt
            context.insert(script)
            script.project = project
            summary.scriptsAdded += 1
            for bh in bs.highlights {
                // Only re-create links whose list made it into the import (skip orphans).
                guard let listUUID = bh.listUUID, let list = listsByOriginalUUID[listUUID] else { continue }
                let h = ScriptHighlight(rangeStart: bh.rangeStart, rangeLength: bh.rangeLength,
                                        excerpt: bh.excerpt, contextBefore: bh.contextBefore,
                                        contextAfter: bh.contextAfter, sceneHeading: bh.sceneHeading)
                context.insert(h)
                h.script = script
                h.list = list
            }
        }

        for bp in manifest.projects {
            var fresh = bp; fresh.uuid = UUID()
            fresh.name = uniqueName(bp.name)
            let project = ProjectData.fromBackup(fresh)
            context.insert(project)
            summary.projectsAdded += 1
            for bl in bp.lists           { _ = insertList(bl, project: project) }
            for pin in bp.importedPhotos { insertPin(pin, list: nil, project: project) }
            for bs in bp.scripts ?? []   { insertScript(bs, project: project) }
        }

        // Standalone lists and unfiled pins (edge cases — wrap in a project named after the file)
        if !manifest.standaloneLists.isEmpty || !manifest.unfiledPins.isEmpty {
            let wrapperName = uniqueName("Imported")
            let wrapper = ProjectData(name: wrapperName, notes: "")
            context.insert(wrapper)
            summary.projectsAdded += 1
            for bl in manifest.standaloneLists { _ = insertList(bl, project: wrapper) }
            for bp in manifest.unfiledPins     { insertPin(bp, list: nil, project: wrapper) }
        }

        try? context.save()
        return summary
    }

    // MARK: - Relink original files

    struct RelinkSummary {
        var linked: Int = 0
        var notFound: Int = 0
    }

    /// Scans `folder` recursively for image files and updates `originalFilePath` on any pin
    /// whose stored basename matches a found file. Only updates pins whose current path is
    /// missing or unreadable (sandbox-expired), so already-working links are untouched.
    static func relinkOriginals(folder: URL, context: ModelContext) async -> RelinkSummary {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var filesByBasename: [String: String] = [:]  // basename → absolute path
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["jpg","jpeg","heic","heif","raw","arw","cr2","cr3","nef","dng","tiff","tif","png"].contains(ext) else { continue }
            filesByBasename[url.lastPathComponent] = url.path
        }

        let pins = (try? context.fetch(FetchDescriptor<PinnedLocationData>())) ?? []
        var summary = RelinkSummary()

        for pin in pins {
            guard let rawPath = pin.originalFilePath else { continue }
            let basename = URL(fileURLWithPath: rawPath).lastPathComponent
            let isAlreadyReadable = fm.isReadableFile(atPath: rawPath)
            guard !isAlreadyReadable else { continue }  // still works, leave it

            if let newPath = filesByBasename[basename] {
                pin.originalFilePath = newPath
                summary.linked += 1
            } else {
                summary.notFound += 1
            }
        }

        try? context.save()
        return summary
    }

    // MARK: - Helpers

    private static func backupPin(_ pin: PinnedLocationData) -> BackupPin {
        // photoFiles (2048px) are omitted from exports — thumbnailFiles only.
        // Carousel falls back to thumbnails on restore; originals can be relinked.
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
            photoFiles: [],
            thumbnailFiles: pin.thumbnailFiles,
            originalFileBasename: pin.originalFilePath.map { URL(fileURLWithPath: $0).lastPathComponent },
            hasGPS: pin.hasGPS,
            gpsFromTimeline: pin.gpsFromTimeline,
            dateTaken: pin.dateTaken,
            googlePlaceId: pin.googlePlaceId,
            sourceURLString: pin.sourceURLString,
            googleMapsURLString: pin.googleMapsURLString,
            imageURL: pin.imageURL,
            deletedAt: pin.deletedAt
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

    // MARK: - Zip / unzip via /usr/bin/zip
    // Works in debug (non-sandboxed) builds. If sandbox is ever re-enabled,
    // replace with a proper zip library (e.g. ZipFoundation).

    #if os(macOS)
    private static func zip(sourceDir: URL, to dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-r", dest.path, "."]
        proc.currentDirectoryURL = sourceDir
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BackupError.zipFailed(proc.terminationStatus)
        }
    }

    private static func unzip(archive: URL, to dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", archive.path, "-d", dest.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BackupError.unzipFailed(proc.terminationStatus)
        }
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
    static func fromBackup(_ b: BackupPin) -> PinnedLocationData {
        let coord = CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)
        let loc = ScoutLocation(id: b.uuid, name: b.name, description: b.notes,
                                coordinate: coord, images: [])
        let pin = PinnedLocationData(from: loc, sortOrder: b.sortOrder)
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
        // originalFilePath is left nil — user relinks after import.
        return pin
    }
}

extension LocationListData {
    static func fromBackup(_ b: BackupList) -> LocationListData {
        let list = LocationListData(name: b.name, colorHex: b.colorHex)
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
    static func fromBackup(_ b: BackupProject) -> ProjectData {
        let p = ProjectData(name: b.name, notes: b.notes)
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
