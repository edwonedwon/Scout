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

        // Debug (Xcode) builds use separate local files so dev test data never mixes with the
        // TestFlight/App Store store (both builds share one sandbox container — same bundle id).
        // The cloud sides are already isolated: Debug → CloudKit Development, TestFlight → Production.
        #if DEBUG
        let storeSuffix = "-dev"
        #else
        let storeSuffix = ""
        #endif

        // --- Private database store (the user's own data) ---
        let privateDesc = base
        privateDesc.url = inMemory ? URL(fileURLWithPath: "/dev/null")
                                   : baseURL.appendingPathComponent("private\(storeSuffix).sqlite")
        privateDesc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        privateDesc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        // CloudKit sync is OFF. The app's data layer is now PowerSync + Supabase — the iOS and Mac
        // UIs read the store, not Core Data. Leaving NSPersistentCloudKitContainer's CloudKit options
        // on spun up a sync engine that downloaded the old pre-migration iCloud dataset on launch, a
        // ~60s main-thread stall before the user could even log in. This residual Core Data store is
        // now LOCAL-ONLY and unused (full removal is migration plan P7). The former two-store
        // (private + shared) CKShare setup is gone too — collaboration is Supabase (project_members
        // + RLS) now.
        privateDesc.cloudKitContainerOptions = nil
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

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        // No PhotoBlobSync / CloudKit remote-change observers: photos now live in Supabase Storage,
        // and nothing reads this store, so launch does zero Core Data sync work.
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
            let share = try await withTimeout(15, step: "creating the share") {
                try await self.shareForProject(project)
            }
            share[CKShare.SystemFieldKey.title] = project.name as CKRecordValue
            share.publicPermission = editor ? .readWrite : .readOnly

            // If the share already has a URL (e.g. it existed from a prior share), use it.
            if let url = share.url {
                dlog("Invite link ready (existing): \(url)", level: .success, tag: "Share")
                return url
            }

            // Persist the share to CloudKit — THIS is the call that saves it to the server and
            // assigns the URL. Await it (with a generous timeout); the first share can be slow
            // while CloudKit creates the share schema. Surface the real error if it fails.
            dlog("Persisting share to iCloud to obtain the link…", tag: "Share")
            let saved = try await withTimeout(60, step: "saving the share to iCloud") {
                try await self.container.persistUpdatedShare(share, in: privateStore)
            }
            guard let url = saved.url else {
                dlog("Share persisted but no URL was assigned", level: .error, tag: "Share")
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
