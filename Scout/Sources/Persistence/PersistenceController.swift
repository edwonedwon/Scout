import CoreData
import CloudKit
import ScoutKit

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

        // Private CloudKit sync — explicitly ON. This is the user's own data mirrored to their
        // private CloudKit database (iCloud.com.cutetech.scout), so projects sync Mac ↔ iPhone.
        //
        // NOTE: `NSPersistentCloudKitContainer` already auto-attaches CloudKit options to its
        // default store description when the app carries the CloudKit entitlement, so sync was
        // in fact live even when these lines were commented out. We now set them explicitly so
        // the behaviour is intentional, visible, and not dependent on that implicit default.
        // For a true LOCAL-ONLY store, set `privateDesc.cloudKitContainerOptions = nil` instead.
        //
        // CloudKit schema requirements (audited — the model satisfies all): every relationship
        // is optional, has an explicit inverse, and uses a Nullify delete rule (no .cascade on
        // optional relationships); every attribute is optional or has a default value.
        if inMemory {
            // Previews / tests: never touch iCloud.
            privateDesc.cloudKitContainerOptions = nil
        } else {
            let privateOpts = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerID)
            privateOpts.databaseScope = .private
            privateDesc.cloudKitContainerOptions = privateOpts
        }

        // --- Shared database store (projects shared TO this user) ---
        // Required for CKShare collaboration: accepted shares land in the shared CloudKit
        // database, mirrored into this local store. New objects the user creates still default
        // to the FIRST store (private) — Core Data auto-assigns to the first applicable store —
        // so normal inserts need no explicit `assign(_:to:)`. Skip entirely for in-memory.
        if inMemory {
            container.persistentStoreDescriptions = [privateDesc]
        } else {
            let sharedDesc = privateDesc.copy() as! NSPersistentStoreDescription
            sharedDesc.url = baseURL.appendingPathComponent("shared.sqlite")
            let sharedOpts = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainerID)
            sharedOpts.databaseScope = .shared
            sharedDesc.cloudKitContainerOptions = sharedOpts
            sharedDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            sharedDesc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            // Private MUST come first so plain inserts auto-assign to it.
            container.persistentStoreDescriptions = [privateDesc, sharedDesc]
        }

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

        // Photo blobs (CKAssets) sync independently of the disk cache. Reconcile once on launch
        // (uploads any local derivatives not yet synced; materializes any synced blobs missing
        // locally) and again on every remote change (so blobs arriving from another device land
        // on disk where the file-based image views can render them). Skip for in-memory stores.
        if !inMemory {
            PhotoBlobSync.reconcile(container: container)
            NotificationCenter.default.addObserver(
                forName: .NSPersistentStoreRemoteChange,
                object: container.persistentStoreCoordinator,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                PhotoBlobSync.reconcile(container: self.container)
            }
        }
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

    /// The CloudKit container backing sharing (needed to drive the system share UI).
    var cloudKitContainer: CKContainer { CKContainer(identifier: Self.cloudContainerID) }

    /// Returns the project's existing `CKShare`, or creates a new one. The returned share is
    /// handed to the system sharing UI (`UICloudSharingController` / `NSSharingServicePicker`)
    /// which manages participants and editor/viewer permissions.
    func shareForProject(_ project: ProjectData) async throws -> CKShare {
        if let existing = existingShare(for: project) { return existing }
        let (_, share, _) = try await container.share([project], to: nil)
        share[CKShare.SystemFieldKey.title] = project.name as CKRecordValue
        return share
    }

    enum SharingError: LocalizedError {
        case noPrivateStore, noURL, timedOut(String)
        var errorDescription: String? {
            switch self {
            case .noPrivateStore: return "iCloud private store isn't loaded."
            case .noURL: return "CloudKit didn't return an invite link (is iCloud signed in and the schema deployed?)."
            case .timedOut(let step): return "Timed out at: \(step). Likely the CloudKit schema isn't deployed to Production, or iCloud isn't reachable/signed in."
            }
        }
    }

    /// Create-or-fetch the project's share, set its link permission (anyone-with-link can edit or
    /// view), persist it to CloudKit, and return the shareable invite URL. This is the reliable
    /// cross-platform path (no dependency on the flaky AppKit sharing picker): the owner copies
    /// the link and sends it; the recipient opens it and the app's accept handler runs.
    func makeShareLink(for project: ProjectData, editor: Bool) async throws -> URL {
        guard let privateStore else {
            dlog("No private store loaded", level: .error, tag: "Share")
            throw SharingError.noPrivateStore
        }
        do {
            dlog("Creating/fetching CKShare for \(project.name)…", tag: "Share")
            let share = try await withTimeout(30, step: "creating the share") {
                try await self.shareForProject(project)
            }
            dlog("Got share; setting \(editor ? "edit" : "view") permission + persisting…", tag: "Share")
            share[CKShare.SystemFieldKey.title] = project.name as CKRecordValue
            share.publicPermission = editor ? .readWrite : .readOnly
            let saved = try await withTimeout(30, step: "saving the share to iCloud") {
                try await self.container.persistUpdatedShare(share, in: privateStore)
            }
            guard let url = saved.url else {
                dlog("Share saved but no URL returned", level: .error, tag: "Share")
                throw SharingError.noURL
            }
            dlog("Invite link ready: \(url)", level: .success, tag: "Share")
            return url
        } catch {
            dlog("Share failed: \(error.localizedDescription)", level: .error, tag: "Share")
            throw error
        }
    }

    /// Runs `work`, throwing `SharingError.timedOut(step)` if it doesn't finish within `seconds`
    /// (so a stuck CloudKit call surfaces as a visible error instead of an infinite spinner).
    private func withTimeout<T>(_ seconds: Double, step: String,
                                _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SharingError.timedOut(step)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Accept a share the user tapped (from Messages/Mail). Called by the app delegate.
    /// The accepted records are mirrored into the local SHARED store.
    func acceptShare(metadata: CKShare.Metadata) {
        guard let sharedStore else { print("acceptShare: shared store not loaded"); return }
        container.acceptShareInvitations(from: [metadata], into: sharedStore) { _, error in
            if let error { print("acceptShare error: \(error)") }
        }
    }
}
