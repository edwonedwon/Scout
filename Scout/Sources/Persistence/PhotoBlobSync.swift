import CoreData
import Foundation
import Combine

/// Observable photo-download progress for the always-visible sync bar. Updated by every
/// `PhotoBlobSync.reconcile` pass: `total` referenced derivatives vs how many are on disk.
@MainActor
final class PhotoSyncProgress: ObservableObject {
    static let shared = PhotoSyncProgress()
    @Published private(set) var downloaded = 0
    @Published private(set) var total = 0

    /// True while there are still derivatives referenced by pins that aren't on disk yet.
    var isDownloading: Bool { total > 0 && downloaded < total }
    var fraction: Double { total > 0 ? Double(downloaded) / Double(total) : 0 }

    func update(downloaded: Int, total: Int) {
        self.downloaded = downloaded
        self.total = total
    }
}

/// Core Data entity that carries a photo's JPEG bytes through CloudKit.
///
/// `PinPhotoStore` keeps photos as files on disk keyed by filename, and only the *filenames*
/// live on `PinnedLocationData` — so files never sync between devices on their own. This entity
/// closes that gap: its `data` attribute uses **external binary storage**, which
/// `NSPersistentCloudKitContainer` automatically uploads as a **CKAsset** through the private
/// database. One row per photo filename (e.g. `<uuid>-0-thumb.jpg` / `<uuid>-0-full.jpg`).
///
/// Only thumbnails (300px) and full-res (2048px) derivatives are synced — NOT the user's original
/// camera files (those stay local via `originalFilePath`).
@objc(PhotoBlobData)
final class PhotoBlobData: NSManagedObject {
    @NSManaged var filename: String?
    @NSManaged var data: Data?
    @NSManaged var createdAt: Date?
    /// The pin that owns this derivative. Set so the blob is reachable from the project's
    /// record graph and is therefore included when the project is shared via CKShare.
    @NSManaged var pin: PinnedLocationData?
}

/// Bidirectional reconcile between the on-disk photo cache and the synced `PhotoBlobData` rows.
///
/// Run on launch and whenever CloudKit posts a remote change:
/// - **Upload:** a derivative file on disk that no blob covers yet → create a blob (syncs up).
/// - **Materialize:** a blob synced down whose file is missing on disk → write the file so the
///   existing file-based image views render it with no caller changes.
enum PhotoBlobSync {
    /// Posted (on main) after `reconcile` writes at least one file to disk, so views can refresh.
    static let didMaterializeNotification = Notification.Name("PhotoBlobSyncDidMaterialize")

    /// Reconcile on a private background context. Safe to call repeatedly; it's idempotent.
    static func reconcile(container: NSPersistentCloudKitContainer) {
        let ctx = container.newBackgroundContext()
        ctx.perform {
            var uploaded = 0
            var materialized = 0

            // --- Index existing blobs by filename (dedup: CloudKit may sync duplicates) ---
            let blobReq = NSFetchRequest<PhotoBlobData>(entityName: "PhotoBlobData")
            let blobs = (try? ctx.fetch(blobReq)) ?? []
            var blobsByName: [String: PhotoBlobData] = [:]
            for b in blobs {
                guard let name = b.filename else { continue }
                if blobsByName[name] == nil { blobsByName[name] = b }
            }

            // --- Map every derivative filename (thumb + full only) to its owning pin ---
            // Skip trashed pins so deleted/duplicate data doesn't inflate counts or re-upload.
            let pinReq = NSFetchRequest<PinnedLocationData>(entityName: "PinnedLocationData")
            pinReq.predicate = NSPredicate(format: "deletedAt == nil")
            let pins = (try? ctx.fetch(pinReq)) ?? []
            var ownerByName: [String: PinnedLocationData] = [:]
            for pin in pins {
                for name in (pin.thumbnailFiles + pin.photoFiles) where ownerByName[name] == nil {
                    ownerByName[name] = pin
                }
            }

            // --- Upload: file on disk, no blob yet → create blob linked to its pin ---
            for (name, owner) in ownerByName where blobsByName[name] == nil {
                let url = PinPhotoStore.fileURL(name)
                guard let bytes = try? Data(contentsOf: url), !bytes.isEmpty else { continue }
                let blob = PhotoBlobData(context: ctx)
                blob.filename = name
                blob.data = bytes
                blob.createdAt = Date()
                blob.pin = owner
                blobsByName[name] = blob
                uploaded += 1
            }

            // --- Backfill: existing blobs missing their pin link (pre-relationship rows) ---
            for (name, blob) in blobsByName where blob.pin == nil {
                if let owner = ownerByName[name] { blob.pin = owner }
            }

            // --- Materialize: blob present, file missing on disk → write file ---
            for (name, blob) in blobsByName {
                let url = PinPhotoStore.fileURL(name)
                guard !FileManager.default.fileExists(atPath: url.path),
                      let bytes = blob.data, !bytes.isEmpty else { continue }
                if (try? bytes.write(to: url)) != nil { materialized += 1 }
            }

            if ctx.hasChanges { try? ctx.save() }

            // Progress is counted in PHOTOS, not files: each photo has one thumbnail + one
            // full-res blob, so we count the THUMBNAIL blobs only (one per photo). On the owner
            // every blob was created from a local file → all on disk → bar hides. On a recipient,
            // blobs sync down with no local file yet → bar shows and climbs as they materialize.
            let photoBlobs = blobsByName.values.filter { ($0.filename ?? "").contains("-thumb") }
            let total = photoBlobs.count
            let onDisk = photoBlobs.reduce(0) { acc, blob in
                guard let name = blob.filename else { return acc }
                return FileManager.default.fileExists(atPath: PinPhotoStore.fileURL(name).path) ? acc + 1 : acc
            }
            Task { @MainActor in PhotoSyncProgress.shared.update(downloaded: onDisk, total: total) }

            if materialized > 0 {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: didMaterializeNotification, object: nil)
                }
            }
            #if DEBUG
            if uploaded > 0 || materialized > 0 {
                print("PhotoBlobSync: uploaded \(uploaded) blobs, materialized \(materialized) files")
            }
            #endif
        }
    }
}
