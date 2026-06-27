import CoreData
import CloudKit

/// Core Data + CloudKit stack for project sharing (docs/collaboration-plan.md, Path B).
///
/// Uses `NSPersistentCloudKitContainer` with TWO stores backed by the same model:
/// - **private** — the user's own projects (their private CloudKit database)
/// - **shared**  — projects others have shared with them (the shared CloudKit database)
///
/// This two-store setup is Apple's recommended pattern for Notes-style sharing
/// (`CKShare` with `.readWrite` / `.readOnly` participants).
///
/// NOT yet wired into the app — the views still run on SwiftData. This is the migration
/// backbone; the Core Data model, NSManagedObject types, view migration, and the
/// SwiftData→Core Data data bridge (via backup import) come in subsequent steps. Because
/// nothing accesses `shared` yet (Swift statics are lazy), the missing model file can't crash
/// the running app.
final class PersistenceController {
    static let shared = PersistenceController()

    /// The container id provisioned for this app (see Scout.entitlements).
    static let cloudContainerID = "iCloud.com.cutetech.scout"

    let container: NSPersistentCloudKitContainer

    private(set) var privateStore: NSPersistentStore?
    private(set) var sharedStore: NSPersistentStore?

    init(inMemory: Bool = false) {
        container = NSPersistentCloudKitContainer(name: "ScoutModel")

        guard let base = container.persistentStoreDescriptions.first,
              let baseURL = base.url?.deletingLastPathComponent() else {
            fatalError("PersistenceController: no base store description")
        }

        // --- Private database store (the user's own data) ---
        let privateDesc = base
        privateDesc.url = inMemory ? URL(fileURLWithPath: "/dev/null")
                                   : baseURL.appendingPathComponent("private.sqlite")
        privateDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDesc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        // TODO(plan 1f): enable private CloudKit sync by restoring these two lines. Kept OFF for
        // the local cut-over so store load can't fail on iCloud provisioning while we verify the
        // SwiftData→Core Data migration + data bridge in isolation. (History tracking stays on so
        // turning sync on later needs no store migration.)
        // let privateOpts = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerID)
        // privateOpts.databaseScope = .private
        // privateDesc.cloudKitContainerOptions = privateOpts

        // --- Shared database store (projects shared TO this user) ---
        // Added in the sharing phase (collaboration-plan.md phase 3). It's intentionally NOT
        // loaded yet: with two stores holding the same entities, every freshly-inserted object
        // would need an explicit `assign(_:to:)` to disambiguate its store. Phase 1 (private
        // CloudKit sync) is single-store, so inserts and `obtainPermanentIDs` stay clean. The
        // accept-share flow that needs the shared store will re-enable it here.
        container.persistentStoreDescriptions = [privateDesc]

        container.loadPersistentStores { [weak self] desc, error in
            if let error { fatalError("PersistenceController: failed to load store: \(error)") }
            guard let self, let url = desc.url,
                  let store = self.container.persistentStoreCoordinator.persistentStore(for: url) else { return }
            switch desc.cloudKitContainerOptions?.databaseScope {
            case .private: self.privateStore = store
            case .shared:  self.sharedStore = store
            default: break
            }
        }

        // The shared DB pushes changes in via the parent context; merge them live, and let the
        // most recent write win at the property level (location data, not prose — see plan).
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    // MARK: - Sharing helpers (thin wrappers over NSPersistentCloudKitContainer)

    /// The existing `CKShare` for an object, if it's already shared.
    func existingShare(for object: NSManagedObject) -> CKShare? {
        (try? container.fetchShares(matching: [object.objectID]))?[object.objectID]
    }

    /// True if the object lives in the SHARED store (i.e. it was shared TO us, not owned by us).
    func isInSharedStore(_ object: NSManagedObject) -> Bool {
        guard let sharedStore else { return false }
        return object.objectID.persistentStore == sharedStore
    }
}
