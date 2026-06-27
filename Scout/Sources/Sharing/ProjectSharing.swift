import SwiftUI
import CloudKit
import CoreData

/// Presents the system CloudKit sharing UI for a `ProjectData`. The owner adds participants
/// (by Apple ID) and chooses editor/viewer permissions there; CloudKit handles the invite link
/// and acceptance. Lists, pins, notes, scripts and (via the blob↔pin link) photos all travel to
/// the participant because they're reachable from the shared project record.
enum ProjectSharing {
    /// Create-or-fetch the share, then present the platform sharing UI. Call from the main actor.
    @MainActor
    static func presentShareUI(for project: ProjectData) async {
        let persistence = PersistenceController.shared
        do {
            let share = try await persistence.shareForProject(project)
            present(share: share, container: persistence.cloudKitContainer, title: project.name)
        } catch {
            print("ProjectSharing: failed to create share — \(error)")
        }
    }

    #if os(macOS)
    // Strong-held delegate for the lifetime of the picker (the picker doesn't retain it).
    private static var macDelegate: MacCloudShareDelegate?

    @MainActor
    private static func present(share: CKShare, container: CKContainer, title: String) {
        guard let anchor = NSApp.keyWindow?.contentView else { return }
        let delegate = MacCloudShareDelegate(container: container, title: title)
        macDelegate = delegate
        let picker = NSSharingServicePicker(items: [share])
        picker.delegate = delegate
        // Anchor near the top-right (where the collaboration button lives) and drop downward.
        // SwiftUI's hosting view is flipped (y=0 at top), so account for both orientations:
        // the "top" edge is minY when flipped, maxY otherwise, and we drop from the matching edge.
        let flipped = anchor.isFlipped
        let topY = flipped ? anchor.bounds.minY + 4 : anchor.bounds.maxY - 4
        let edge: NSRectEdge = flipped ? .maxY : .minY
        let rect = NSRect(x: anchor.bounds.maxX - 80, y: topY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: anchor, preferredEdge: edge)
    }
    #else
    @MainActor
    private static func present(share: CKShare, container: CKContainer, title: String) {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowReadWrite, .allowReadOnly, .allowPrivate]
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        if let pop = controller.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
    #endif
}

#if os(macOS)
import AppKit

/// Supplies the CKContainer + share title to the macOS sharing picker so the "Collaborate"
/// (CloudKit) service is offered and configured correctly.
final class MacCloudShareDelegate: NSObject, NSSharingServicePickerDelegate, NSCloudSharingServiceDelegate {
    let container: CKContainer
    let title: String
    init(container: CKContainer, title: String) { self.container = container; self.title = title }

    func sharingServicePicker(_ picker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingService(_ sharingService: NSSharingService,
                        sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        NSApp.keyWindow
    }

    // Essential: tell the CloudKit sharing service which container the share lives in.
    func itemsForSharingService(_ sharingService: NSSharingService,
                                cloudKitContainerForItems items: [Any]) -> CKContainer { container }
}
#endif
