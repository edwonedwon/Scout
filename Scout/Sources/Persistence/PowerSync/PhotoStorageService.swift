import Foundation
import Supabase

extension Notification.Name {
    /// Posted (main thread) after a photo file is downloaded from Storage to the local cache, so
    /// image views currently showing a "still downloading" placeholder can reload.
    static let photoDidMaterialize = Notification.Name("scout.photoDidMaterialize")
}

/// Photo files in Supabase Storage (migration plan P5). Photos never travel through PowerSync sync
/// (that's for row data) — only filename references live in the `pins` rows; the bytes live here.
///
/// Three tiers per photo, each its own object:
///   • `.thumbnail` (~300px) — tiny; fetched on demand for grid/map/sidebar and cached locally.
///   • `.full` (~2048px JPEG) — the normal carousel image; fetched when a photo is opened.
///   • `.original` — the untouched source file. Stored for everyone, but **downloaded only when the
///     user opts in** (Settings → "Download originals"), since most users never need them and they
///     are large. Off by default.
///
/// Storage path convention: `{projectId}/{tier}/{filename}` — the leading projectId lets a single
/// Storage RLS policy authorize access via `can_access_project()` (see db/supabase-schema.sql).
struct PhotoStorageService {
    static let bucket = "photos"
    static let shared = PhotoStorageService()

    enum Tier: String { case thumbnail, full, original }

    /// User setting: automatically download original files. Off by default — most users only ever
    /// need thumbnails + the compressed full-res image.
    static let autoDownloadOriginalsKey = "photos.autoDownloadOriginals"
    static var autoDownloadOriginals: Bool {
        UserDefaults.standard.bool(forKey: autoDownloadOriginalsKey)
    }

    private var client: SupabaseClient? { SupabaseService.client }
    private func path(_ projectId: String, _ tier: Tier, _ filename: String) -> String {
        "\(projectId)/\(tier.rawValue)/\(filename)"
    }

    // MARK: - Upload

    /// Upload bytes for one tier. Idempotent (upsert) so re-uploads/retries are safe. No-op when
    /// Storage isn't configured yet, so import/photo flows degrade to local-only cleanly.
    func upload(_ data: Data, projectId: String, tier: Tier, filename: String) async throws {
        guard let client else { return }
        try await client.storage.from(Self.bucket).upload(
            path(projectId, tier, filename),
            data: data,
            options: FileOptions(contentType: Self.contentType(filename), upsert: true)
        )
    }

    /// Convenience: upload a local file (used when importing existing photos).
    func upload(fileURL: URL, projectId: String, tier: Tier, filename: String) async throws {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        try await upload(data, projectId: projectId, tier: tier, filename: filename)
    }

    /// Best-effort upload of a freshly imported pin's locally-cached tiers (thumbnail + full) to
    /// Storage, so the photo reaches other devices. Resolves the pin's project for the Storage path.
    /// No-op when Storage isn't configured, or the pin isn't in any project (an unfiled pin doesn't
    /// sync, so its bytes have nowhere to live). Originals stay local — matching backup import.
    func uploadLocalTiers(pinId: String, fullFiles: [String], thumbnailFiles: [String]) async {
        guard client != nil, !(fullFiles.isEmpty && thumbnailFiles.isEmpty) else { return }
        guard let projectId = await projectId(forPin: pinId) else { return }
        for f in thumbnailFiles {
            try? await upload(fileURL: PinPhotoStore.fileURL(f), projectId: projectId, tier: .thumbnail, filename: f)
        }
        for f in fullFiles {
            try? await upload(fileURL: PinPhotoStore.fileURL(f), projectId: projectId, tier: .full, filename: f)
        }
    }

    // MARK: - Download (with local cache)

    /// Return a local file URL for the given photo, downloading it from Storage into the local
    /// `PinPhotoStore` cache if not already present. Returns nil if the file isn't available
    /// (e.g. an original the user opted not to download, or Storage not configured).
    @discardableResult
    func ensureLocal(filename: String, projectId: String, tier: Tier) async -> URL? {
        let localURL = PinPhotoStore.fileURL(cacheName(filename, tier))
        if FileManager.default.fileExists(atPath: localURL.path) { return localURL }
        guard let client else { return nil }
        do {
            let data = try await client.storage.from(Self.bucket).download(path: path(projectId, tier, filename))
            try data.write(to: localURL)
            return localURL
        } catch {
            return nil
        }
    }

    /// Ensure a pin's displayed thumbnail is in the local cache, downloading it from Storage if it's
    /// missing (the case on a device that didn't create the photo). On success, posts
    /// `.photoDidMaterialize` so on-screen image views reload and show it. The thumbnail tier caches
    /// at the bare filename — exactly where the thumbnail image views look — so no rename is needed.
    func ensureThumbnailLocal(projectId: String, thumbnailFiles: [String]) async {
        guard client != nil, let file = thumbnailFiles.first else { return }
        if FileManager.default.fileExists(atPath: PinPhotoStore.fileURL(file).path) { return }
        if await ensureLocal(filename: file, projectId: projectId, tier: .thumbnail) != nil {
            // Target the reload at the one file that materialized (object = filename), so only the
            // image view showing it reloads — not every on-screen photo.
            await MainActor.run { NotificationCenter.default.post(name: .photoDidMaterialize, object: file) }
        }
    }

    /// Pre-download a project's thumbnails into the local cache, a few at a time so the network/UI
    /// never gets flooded. Downloads in the caller's order (top-to-bottom grid order). Crucially it
    /// RETRIES across several passes: a thumbnail that fails (a network blip, or the app being
    /// suspended mid-download) is re-attempted next pass, so the prefetch actually runs to
    /// completion instead of leaving permanent placeholders. Stops once everything is cached, a pass
    /// makes no new progress (the rest genuinely aren't in Storage), or the task is cancelled.
    func prefetchThumbnails(projectId: String, files: [String], maxConcurrent: Int = 5) async {
        guard client != nil else { return }
        var dedup = Set<String>()
        let unique = files.filter { dedup.insert($0).inserted }
        func stillMissing() -> [String] {
            unique.filter { !FileManager.default.fileExists(atPath: PinPhotoStore.fileURL($0).path) }
        }
        let initialMissing = stillMissing().count
        guard initialMissing > 0 else { await PhotoSyncProgress.shared.update(downloaded: 0, total: 0); return }

        var gotTotal = 0
        for pass in 0..<6 {
            if Task.isCancelled { break }
            let toGet = stillMissing()
            if toGet.isEmpty { break }
            await PhotoSyncProgress.shared.update(downloaded: gotTotal, total: initialMissing)
            var gotThisPass = 0
            var i = 0
            while i < toGet.count {
                if Task.isCancelled { break }
                let chunk = toGet[i ..< min(i + maxConcurrent, toGet.count)]
                let got = await withTaskGroup(of: Bool.self) { group -> Int in
                    for file in chunk {
                        group.addTask {
                            guard await self.ensureLocal(filename: file, projectId: projectId, tier: .thumbnail) != nil
                            else { return false }
                            await MainActor.run { NotificationCenter.default.post(name: .photoDidMaterialize, object: file) }
                            return true
                        }
                    }
                    var c = 0
                    for await ok in group where ok { c += 1 }
                    return c
                }
                gotThisPass += got; gotTotal += got
                await PhotoSyncProgress.shared.update(downloaded: gotTotal, total: initialMissing)
                i += maxConcurrent
            }
            if gotThisPass == 0 { break }   // a whole pass got nothing new → the rest aren't available
            if pass < 5 { try? await Task.sleep(nanoseconds: 1_500_000_000) }   // brief backoff before retry
        }
        await PhotoSyncProgress.shared.update(downloaded: 0, total: 0)   // finished → hide the bar
    }

    /// Fetch every photo's thumbnail for a pin (the always-available tier). Originals are skipped
    /// unless `autoDownloadOriginals` is on.
    func prefetch(pin: PinRecord) async {
        var resolvedProjectId = pin.owningProjectId
        if resolvedProjectId == nil, let listId = pin.listId {
            resolvedProjectId = await projectId(forList: listId)
        }
        guard let projectId = resolvedProjectId else { return }
        for file in pin.thumbnailFiles {
            _ = await ensureLocal(filename: file, projectId: projectId, tier: .thumbnail)
        }
        if Self.autoDownloadOriginals, let original = pin.originalFilename {
            _ = await ensureLocal(filename: original, projectId: projectId, tier: .original)
        }
    }

    /// Explicit, user-initiated original download (the "Download original" button), independent of
    /// the default-off setting.
    @discardableResult
    func downloadOriginal(filename: String, projectId: String) async -> URL? {
        await ensureLocal(filename: filename, projectId: projectId, tier: .original)
    }

    // MARK: - Delete

    func remove(projectId: String, tier: Tier, filename: String) async {
        guard let client else { return }
        _ = try? await client.storage.from(Self.bucket).remove(paths: [path(projectId, tier, filename)])
    }

    // MARK: - Helpers

    /// Resolve a pin's owning project — directly (unfiled pin) or via its list. Nil for a pin that
    /// belongs to no project (it won't sync, so its photos have no Storage home).
    private func projectId(forPin pinId: String) async -> String? {
        try? await ScoutStore.shared.db.getOptional(
            sql: """
            SELECT coalesce(p.owning_project_id, l.project_id) AS project_id
            FROM pins p LEFT JOIN location_lists l ON l.id = p.list_id
            WHERE p.id = ?
            """,
            parameters: [pinId]
        ) { try $0.getStringOptional(name: "project_id") } ?? nil
    }

    /// Look up which project a list belongs to (needed to build the Storage path for list pins).
    private func projectId(forList listId: String) async -> String? {
        try? await ScoutStore.shared.db.getOptional(
            sql: "SELECT project_id FROM location_lists WHERE id = ?",
            parameters: [listId]
        ) { try $0.getStringOptional(name: "project_id") } ?? nil
    }

    /// Local cache filename, namespaced by tier so the three tiers never collide on disk.
    private func cacheName(_ filename: String, _ tier: Tier) -> String {
        tier == .thumbnail ? filename : "\(tier.rawValue)-\(filename)"
    }

    private static func contentType(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "heic", "hif": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        default: return "image/jpeg"
        }
    }
}
