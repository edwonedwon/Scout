import SwiftUI
import MapKit
import ScoutKit

// Backup export/import, relink, photo backfill, delete-all.
extension ContentView {
    // Backup/restore File-menu handlers are macOS-only (NSOpenPanel/NSSavePanel).
    #if os(macOS)
    @MainActor
    func handleExport() async {
        guard !isBackupBusy else { return }
        guard !openProjectUUID.isEmpty,
              let project = allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })
        else { backupStatusMessage = "Open a project first to export it."; return }
        isBackupBusy = true
        backupStatusMessage = nil
        do {
            let zipURL = try await BackupService.export(project: project)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = zipURL.lastPathComponent
            panel.allowedContentTypes = [.zip]
            // Sandbox-safe: runModal() brings the panel up non-resizable; use async begin.
            let dest: URL? = await withCheckedContinuation { cont in
                DispatchQueue.main.async {
                    panel.begin { cont.resume(returning: $0 == .OK ? panel.url : nil) }
                }
            }
            guard let dest else {
                try? FileManager.default.removeItem(at: zipURL)
                isBackupBusy = false
                return
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: zipURL, to: dest)
            try? FileManager.default.removeItem(at: zipURL)
            backupStatusMessage = "Exported \"\(project.name)\" to \(dest.lastPathComponent)"
        } catch {
            backupStatusMessage = "Export failed: \(error.localizedDescription)"
        }
        isBackupBusy = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { backupStatusMessage = nil }
    }

    @MainActor
    func handleImport() async {
        guard !isBackupBusy else { return }
        isBackupBusy = true
        backupStatusMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Select a Scout backup archive"
        let picked: URL? = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                panel.begin { cont.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        guard let url = picked else { isBackupBusy = false; return }
        do {
            // Import into ScoutStore (PowerSync) — syncs up to Supabase and copies photo bytes to
            // the local cache (and Storage when configured). Replaces the old Core Data import.
            DebugLogger.shared.log("User picked backup: \(url.lastPathComponent)", tag: "Import")
            let s = try await BackupService.importIntoStore(from: url)
            backupStatusMessage = "Imported \(s.projectsAdded) projects, \(s.listsAdded) lists, \(s.pinsAdded) pins. Skipped \(s.skippedDuplicates) duplicates."
        } catch {
            DebugLogger.shared.log("Import FAILED: \(error)", level: .error, tag: "Import")
            backupStatusMessage = "Import failed: \(error.localizedDescription)"
        }
        isBackupBusy = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { backupStatusMessage = nil }
    }

    @MainActor
    func handleRelink() async {
        guard !isBackupBusy else { return }
        isBackupBusy = true
        backupStatusMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select folder containing your original photo files"
        let picked: URL? = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                panel.begin { cont.resume(returning: $0 == .OK ? panel.url : nil) }
            }
        }
        guard let url = picked else { isBackupBusy = false; return }
        backupProgress = 0
        let result = await BackupService.relinkOriginals(folder: url) { stage, frac in
            Task { @MainActor in
                backupStatusMessage = stage
                backupProgress = frac
            }
        }
        backupProgress = nil
        backupStatusMessage = "Relinked \(result.linked) of \(result.linked + result.notFound) photos "
            + "(\(result.photosGenerated) images rebuilt, \(result.notFound) not found) from \(result.scanned) files."
        isBackupBusy = false
        // Original-file availability + photoFiles changed (not part of the per-pin signature) → drop caches.
        displayCache.invalidateAll()
        rebuildPinCaches()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { backupStatusMessage = nil }
    }
    #endif

    /// One-time pass over existing pins that have no offline photos yet, fetching them
    /// from their original source (stored URLs, Google place ID, or a name+area search).
    func backfillPhotos() {
        for pin in allPins where pin.photoFiles.isEmpty {
            cachePhotos(pinId: pin.id, from: pin.asScoutLocation())
        }
    }

    /// One-time pass that fills in `aspectRatio` for pins imported before that field existed,
    /// so the photo grid can size cells without waiting for the image to load (no reflow).
    /// File headers are read off the main actor; the model is updated back on main.
    func backfillAspectRatios() {
        // (persistentModelID, thumbnail file URL) for every pin still missing an aspect.
        let targets: [(String, URL)] = allPins.compactMap { pin in
            guard pin.aspectRatio == 0, pin.deletedAt == nil else { return nil }
            guard let file = pin.thumbnailFiles.first ?? pin.photoFiles.first else { return nil }
            return (pin.id, PinPhotoStore.fileURL(file))
        }
        guard !targets.isEmpty else { return }
        Task {
            let results: [String: Double] = await Task.detached(priority: .utility) {
                var r: [String: Double] = [:]
                for (id, url) in targets {
                    if let a = PhotoImportService.aspectRatio(ofImageAt: url) { r[id] = a }
                }
                return r
            }.value
            guard !results.isEmpty else { return }
            for pin in allPins {
                if let a = results[pin.id], pin.aspectRatio == 0 { pin.aspectRatio = a }
            }
            // ScoutLocations cached before backfill lack the aspect → drop and rebuild.
            displayCache.invalidateAll()
            rebuildPinCaches()
        }
    }

    /// AGGRESSIVE manual cleanup (Debug "Clear Old Lists" button): deletes every project,
    /// Deletes every project (cascade removes all lists and pins) and resets nav state.
    /// Safe to call at any time — closes the panel first so no @Bindable view holds a
    /// reference to a model that's about to be deleted.
    func deleteAllData() {
        showProjectsPanel = false
        activeListIDs = []
        openProjectUUID = ""
        let ids = allProjects.map(\.id)
        Task { for id in ids { try? await ScoutStore.shared.purgeProject(id: id) } }
    }
}
