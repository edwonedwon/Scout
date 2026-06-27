import CoreData
import Foundation

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

            // --- Gather every derivative filename referenced by a pin (thumb + full only) ---
            let pinReq = NSFetchRequest<PinnedLocationData>(entityName: "PinnedLocationData")
            let pins = (try? ctx.fetch(pinReq)) ?? []
            var referenced = Set<String>()
            for pin in pins {
                referenced.formUnion(pin.thumbnailFiles)
                referenced.formUnion(pin.photoFiles)
            }

            // --- Upload: file on disk, no blob yet → create blob ---
            for name in referenced where blobsByName[name] == nil {
                let url = PinPhotoStore.fileURL(name)
                guard let bytes = try? Data(contentsOf: url), !bytes.isEmpty else { continue }
                let blob = PhotoBlobData(context: ctx)
                blob.filename = name
                blob.data = bytes
                blob.createdAt = Date()
                blobsByName[name] = blob
                uploaded += 1
            }

            // --- Materialize: blob present, file missing on disk → write file ---
            for (name, blob) in blobsByName {
                let url = PinPhotoStore.fileURL(name)
                guard !FileManager.default.fileExists(atPath: url.path),
                      let bytes = blob.data, !bytes.isEmpty else { continue }
                if (try? bytes.write(to: url)) != nil { materialized += 1 }
            }

            if ctx.hasChanges { try? ctx.save() }

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
