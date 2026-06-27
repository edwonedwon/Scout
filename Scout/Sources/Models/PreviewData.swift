#if DEBUG
import CoreData
import ScoutKit

/// In-memory Core Data stack with one project, one list, and a couple of saved pins —
/// for SwiftUI previews (ContentView, ProjectsPanel). Replaces the former SwiftData
/// `ModelContainer`-based preview data. Inject with
/// `.environment(\.managedObjectContext, PreviewData.context)`.
@MainActor
enum PreviewData {
    static let controller: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.viewContext
        let project = ProjectData(context: ctx, name: "Tokyo Shoot")
        let list = LocationListData(context: ctx, name: "Day 1 — Shibuya", colorHex: LocationListData.palette[1])
        list.project = project
        for (i, loc) in [ScoutLocation.preview, .previewNoPhotos].enumerated() {
            let pin = PinnedLocationData(context: ctx, from: loc, sortOrder: i)
            pin.list = list
        }
        try? ctx.save()
        return controller
    }()

    static var context: NSManagedObjectContext { controller.viewContext }
}
#endif
