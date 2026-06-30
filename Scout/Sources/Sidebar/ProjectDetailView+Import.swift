import SwiftUI
import ScoutKit
import UniformTypeIdentifiers

// Photo / script import + Timeline backfill.
extension ProjectDetailView {
    func importPhotos() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .image,
            .rawImage,           // .cr2, .cr3, .nef, .arw, .dng, .orf, .rw2, etc.
            UTType("public.heif-standard") ?? .heic,  // .heif container
        ]
        panel.allowsOtherFileTypes = true  // fallback for any format CGImageSource can decode
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in await importImageURLs(urls, into: nil) }
        #endif
        // iOS uses PhotosPicker instead — see IOS_PLAN.md (not wired into this Mac sidebar).
    }

    /// Imports one or more `.fountain` scripts: reads each file's text into a new ScriptVM
    /// (copied in, not referenced) under the project's "Scripts" section.
    func importScript() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Import Script"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "fountain") ?? .plainText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        var nextOrder = (project.scripts.map(\.sortOrder).max() ?? -1) + 1
        let pid = project.id
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let order = nextOrder
            Task { try? await ScoutStore.shared.createScript(projectId: pid, name: name, rawText: text, sortOrder: order) }
            nextOrder += 1
        }
        scriptsExpanded = true
        #endif
    }

    /// Picks a Google Maps Timeline JSON export and backfills GPS onto photos that lack it
    /// by matching their EXIF capture time to the timeline's locations.
    func pickTimelineAndBackfill() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Select Google Maps Timeline JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBackfilling = true
        timelineProgress = (0, 0, "")
        DebugLogger.shared.log("Timeline import started…", level: .info)
        Task {
            let result = await TimelineGeoService.backfill(timelineURL: url) { current, total, name in
                timelineProgress = (current, total, name)
            }
            isBackfilling = false
            timelineProgress = nil
            DebugLogger.shared.log(
                "Timeline import done — timezone: \(result.detectedTimezone), updated: \(result.updated), skipped: \(result.skipped), failed: \(result.failed)",
                level: result.failed > 0 ? .warning : .success
            )
            // The store's reactive watch refreshes the map/grid VMs automatically as pins gain GPS.
            _ = result.updatedPinIDs
        }
        #endif
    }

    /// Imports photo files into a list (or top-level when `list` is nil), inserting the
    /// pins and wiring their relationship. Shared by the Import menu and Finder drag-drop.
    @MainActor
    func importImageURLs(_ urls: [URL], into list: ListVM?) async {
        PhotoImportActivity.isImporting = true            // pause the global upload bar during import
        defer { PhotoImportActivity.isImporting = false }
        let dest = list?.name ?? "Uncategorized"
        dlog("import: \(urls.count) file(s) → \(dest)", tag: "Import")

        // Collect all existing pins across this project for duplicate detection. Build the dedup
        // index here (main thread) — it reads managed objects, which importPhotos must not touch.
        let existingPins = (project.lists.flatMap(\.pins)) + project.importedPhotos
        let dedup = PhotoImportService.DedupIndex(existingPins: existingPins)
        let baseSortOrder = list?.pins.count ?? 0

        // Stage 1 — decode + compress (thumbnail + full-res JPEG). This is the CPU-heavy part.
        importProgress = (label: "Importing & compressing", current: 0, total: urls.count)
        let results = await PhotoImportService.importPhotos(from: urls, dedup: dedup,
                                                            baseSortOrder: baseSortOrder) { current, total in
            importProgress = (label: "Importing & compressing", current: current, total: total)
        }
        let gpsCount = results.filter(\.hasGPS).count
        dlog("import: decoded \(results.count)/\(urls.count) (\(gpsCount) geo-tagged, \(urls.count - results.count) skipped/dupe)",
             level: results.isEmpty ? .warning : .info, tag: "Import")

        // Stage 2 — save each pin to the store and upload its tiers to cloud. Keep the overlay up:
        // for large files the upload is the slow part (the old code hid the bar before this began).
        let pid = project.id
        importProgress = (label: "Saving & uploading to cloud", current: 0, total: results.count)
        var nextOrder = sidebarItems.count
        var done = 0, failed = 0
        for result in results {
            let owning = list == nil ? pid : nil
            let panelOrder = list == nil ? nextOrder : 0
            do {
                try await ScoutStore.shared.insertPin(
                    result.storeRecord(listId: list?.id, owningProjectId: owning, panelOrder: panelOrder))
                let thumbOK = FileManager.default.fileExists(atPath: PinPhotoStore.fileURL(result.thumbFilename).path)
                if !thumbOK { dlog("import: \(result.name) — thumbnail file missing on disk!", level: .warning, tag: "Import") }
            } catch {
                failed += 1
                dlog("import: insert FAILED \(result.name): \(error)", level: .error, tag: "Import")
            }
            await PhotoStorageService.shared.uploadLocalTiers(
                pinId: result.id.uuidString, fullFiles: [result.fullFilename], thumbnailFiles: [result.thumbFilename])
            if list == nil { nextOrder += 1 }
            done += 1
            importProgress = (label: "Saving & uploading to cloud", current: done, total: results.count)
        }
        importProgress = nil
        normalizeOrder()
        dlog("import: done — \(done - failed) pin(s) added to \(dest)\(failed > 0 ? ", \(failed) failed" : "")",
             level: failed > 0 ? .warning : .success, tag: "Import")
    }

    /// If `providers` carry Finder image files, kicks off an import into `list`
    /// (top-level when nil) and returns true. Returns false for internal reorder drags
    /// (plain-text drag ids), so the caller can fall back to its move/reorder handler.
    func tryImportDrop(_ providers: [NSItemProvider], into list: ListVM?) -> Bool {
        let hasFiles = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard hasFiles else { return false }
        Task { @MainActor in
            let urls = await loadImageURLs(from: providers)
            guard !urls.isEmpty else { return }
            await importImageURLs(urls, into: list)
        }
        return true
    }
}
