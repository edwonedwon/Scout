import SwiftUI
import SwiftData
import ScoutKit
import CoreLocation
import UniformTypeIdentifiers

// MARK: - Finder drag helpers

let imageExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","webp","gif","bmp","raw","arw","cr2","nef","dng"]

func loadImageURLs(from providers: [NSItemProvider]) async -> [URL] {
    await withTaskGroup(of: URL?.self) { group in
        for provider in providers {
            group.addTask {
                if provider.canLoadObject(ofClass: NSURL.self) {
                    return await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                            if let url = reading as? URL,
                               imageExtensions.contains(url.pathExtension.lowercased()) {
                                cont.resume(returning: url)
                            } else {
                                cont.resume(returning: nil)
                            }
                        }
                    }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    return await withCheckedContinuation { cont in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            let url: URL?
                            if let data = item as? Data {
                                url = URL(dataRepresentation: data, relativeTo: nil)
                            } else {
                                url = item as? URL
                            }
                            if let url, imageExtensions.contains(url.pathExtension.lowercased()) {
                                cont.resume(returning: url)
                            } else {
                                cont.resume(returning: nil)
                            }
                        }
                    }
                }
                return nil
            }
        }
        var urls: [URL] = []
        for await url in group { if let url { urls.append(url) } }
        return urls
    }
}

/// Adjust this to clear the traffic light buttons in the sidebar.
private let sidebarTopPadding: CGFloat = 35

/// Deletes EVERY project, list, and pin in the store via SwiftData batch deletes,
/// logging counts before and after. Must be called only after any open-project detail
/// view has been popped/unmounted (see the purgeTrigger handler), so no @Bindable view
/// is bound to a model being deleted.
@MainActor
func purgeAllProjects(_ context: ModelContext) {
    let projects = (try? context.fetch(FetchDescriptor<ProjectData>())) ?? []
    let listsBefore = (try? context.fetch(FetchDescriptor<LocationListData>())) ?? []

    DebugLogger.shared.log("--- BEFORE PURGE ---", level: .warning, tag: "Purge")
    DebugLogger.shared.log("Projects (\(projects.count)):", level: .info, tag: "Purge")
    for p in projects {
        DebugLogger.shared.log("  📁 \"\(p.name)\" — \(p.lists.count) lists, \(p.importedPhotos.count) photos", level: .info, tag: "Purge")
        for list in p.lists {
            DebugLogger.shared.log("    📋 \"\(list.name)\" — \(list.pins.count) pins", level: .info, tag: "Purge")
        }
    }
    let orphans = listsBefore.filter { $0.project == nil }
    if !orphans.isEmpty {
        DebugLogger.shared.log("Orphaned lists (\(orphans.count)):", level: .info, tag: "Purge")
        for list in orphans {
            DebugLogger.shared.log("  📋 \"\(list.name)\" (no project)", level: .info, tag: "Purge")
        }
    }

    // Delete in a SEPARATE ModelContext on the same container. Two reasons:
    //  1) No crash — the main context's @Query observers (ContentView.projectPins, the
    //     root project ForEach, the `allLists` query that feeds "Save to List") refresh
    //     ASYNCHRONOUSLY when the background save propagates, instead of synchronously
    //     mid-save where they'd re-render against an invalidated model and fault.
    //  2) The menu actually clears — `context.delete(model:)` batch deletes don't reliably
    //     refresh existing @Query results (and silently no-op on the self-referential
    //     list relationship), which left stale lists in the "Save to List" menu. Deleting
    //     real objects per-instance here propagates cleanly to every @Query.
    let purge = ModelContext(context.container)
    for pin in (try? purge.fetch(FetchDescriptor<PinnedLocationData>())) ?? [] { purge.delete(pin) }
    for list in (try? purge.fetch(FetchDescriptor<LocationListData>())) ?? [] { purge.delete(list) }
    for project in (try? purge.fetch(FetchDescriptor<ProjectData>())) ?? [] { purge.delete(project) }
    try? purge.save()

    let projectsAfter = (try? purge.fetch(FetchDescriptor<ProjectData>())) ?? []
    let listsAfter = (try? purge.fetch(FetchDescriptor<LocationListData>())) ?? []
    DebugLogger.shared.log("--- AFTER PURGE ---", level: .warning, tag: "Purge")
    DebugLogger.shared.log("Projects remaining: \(projectsAfter.count)", level: projectsAfter.isEmpty ? .success : .error, tag: "Purge")
    DebugLogger.shared.log("Lists remaining: \(listsAfter.count)", level: listsAfter.isEmpty ? .success : .error, tag: "Purge")
}

// MARK: - Projects panel

struct ProjectsPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectData.createdAt) private var projects: [ProjectData]

    @Binding var activeListIDs: Set<PersistentIdentifier>
    /// Toggled by the debug "Clear Old Lists" button. Flipping it runs the full purge
    /// here (where navPath lives) so nav-pop + delete happen in one atomic transaction.
    var purgeTrigger: Bool = false
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onSelectPin: ((PinnedLocationData) -> Void)? = nil
    var onZoomToPin: ((PinnedLocationData) -> Void)? = nil
    var onClearPin: (() -> Void)? = nil
    var onRevealPins: (([PinnedLocationData]) -> Void)? = nil
    var onOpenCarousel: ((PinnedLocationData) -> Void)? = nil
    /// Set by photo grid to scroll the sidebar to the tapped pin.
    var scrollToPinUUID: UUID? = nil
    /// Set by ContentView (M key or grid context menu) to open the move sheet for these UUIDs.
    @Binding var externalMoveUUIDs: [UUID]

    /// Persisted open project (stored as UUID string, resolved to ProjectData on load).
    @AppStorage("nav.openProjectUUID") private var openProjectUUID: String = ""
    /// Persisted expanded list UUIDs, comma-separated.
    @AppStorage("nav.expandedListUUIDs") private var expandedListUUIDs: String = ""

    @State private var navPath: [ProjectData] = []
    @State private var showAddProject = false
    @State private var newProjectName = ""
    @State private var renamingProject: ProjectData? = nil
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $navPath) {
            projectList
                .navigationDestination(for: ProjectData.self) { project in
                    ProjectDetailView(
                        project: project,
                        initialExpandedUUIDs: storedExpandedUUIDs,
                        activeListIDs: $activeListIDs,
                        onFitToList: onFitToList,
                        onSelectPin: onSelectPin,
                        onZoomToPin: onZoomToPin,
                        onClearPin: onClearPin,
                        onRevealPins: onRevealPins,
                        onOpenCarousel: onOpenCarousel,
                        onExpandedChanged: { uuids in
                            expandedListUUIDs = uuids.joined(separator: ",")
                        },
                        scrollToPinUUID: scrollToPinUUID,
                        externalMoveUUIDs: $externalMoveUUIDs
                    )
                }
        }
        .onAppear {
            // Restore the previously open project.
            if !openProjectUUID.isEmpty,
               let project = projects.first(where: { $0.uuid.uuidString == openProjectUUID }) {
                navPath = [project]
            }
        }
        .onChange(of: navPath) { _, path in
            openProjectUUID = path.first?.uuid.uuidString ?? ""
        }
        // Debug "Clear Old Lists": pop the open project's detail view, THEN delete.
        // The nav pop must be un-animated so the @Bindable ProjectDetailView unmounts in
        // the next frame (an animated pop keeps it alive ~300ms). We then delete on a
        // later runloop, after SwiftUI has torn the detail view down — otherwise the
        // synchronous @Query refresh that save() triggers re-renders a view bound to a
        // deleted project and crashes.
        .onChange(of: purgeTrigger) { _, _ in
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { navPath = [] }
            openProjectUUID = ""
            expandedListUUIDs = ""
            activeListIDs = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                purgeAllProjects(modelContext)
            }
        }
        .sheet(isPresented: $showAddProject) {
            NameEntrySheet(
                title: "New Project",
                placeholder: "Project name",
                text: $newProjectName,
                onDismiss: { showAddProject = false }
            ) { name in
                let p = ProjectData(name: name)
                modelContext.insert(p)
                showAddProject = false
            }
        }
    }

    private var storedExpandedUUIDs: Set<String> {
        Set(expandedListUUIDs.split(separator: ",").map(String.init))
    }

    private var projectList: some View {
        List {
            Color.clear.frame(height: sidebarTopPadding).listRowBackground(Color.clear)
            ForEach(projects) { project in
                NavigationLink(value: project) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.headline)
                        let total = project.lists.count + project.importedPhotos.count
                        if total > 0 {
                            Text("\(project.lists.count) lists · \(project.importedPhotos.count) photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    Button {
                        renameText = project.name
                        renamingProject = project
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        // Pop nav first so NavigationStack doesn't hold a reference
                        // to the deleted project and crash when SwiftUI re-renders.
                        if navPath.first?.persistentModelID == project.persistentModelID {
                            navPath = []
                            openProjectUUID = ""
                            expandedListUUIDs = ""
                        }
                        // Manually detach children before deleting to avoid cascade failures
                        // leaving orphaned lists in the store.
                        for list in project.lists {
                            list.project = nil
                            for pin in list.pins { pin.list = nil }
                            modelContext.delete(list)
                        }
                        for pin in project.importedPhotos {
                            pin.owningProject = nil
                            modelContext.delete(pin)
                        }
                        modelContext.delete(project)
                        try? modelContext.save()
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddProject = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { renamingProject?.name = trimmed }
                try? modelContext.save()
                renamingProject = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { renamingProject = nil }
        }
    }
}

// MARK: - Sidebar selection model

/// Holds the sidebar's multi-selection as a reference type. The parent owns this via
/// plain `@State` (NOT `@StateObject`), so mutating the set does NOT re-render the parent
/// or rebuild the row list. Only the rows themselves observe it via `@ObservedObject`, and
/// because the List is lazy, only the handful of on-screen rows ever repaint — selecting
/// thousands of off-screen rows is an O(1) set assignment with no visual work.
private final class SidebarSelection: ObservableObject {
    @Published var ids: Set<PersistentIdentifier> = []
    var anchor: PersistentIdentifier? = nil

    func contains(_ id: PersistentIdentifier) -> Bool { ids.contains(id) }
}

// MARK: - Sidebar item (unified photo + list)

private enum SidebarItem: Identifiable {
    case photo(PinnedLocationData)
    case list(LocationListData)
    /// A group of photos that share a stackID — shown as one row with a count badge.
    case stack(lead: PinnedLocationData, members: [PinnedLocationData])

    var id: PersistentIdentifier {
        switch self {
        case .photo(let p): return p.persistentModelID
        case .list(let l): return l.persistentModelID
        case .stack(let lead, _): return lead.persistentModelID
        }
    }

    var panelOrder: Int {
        switch self {
        case .photo(let p): return p.panelOrder
        case .list(let l): return l.panelOrder
        case .stack(let lead, _): return lead.panelOrder
        }
    }

    var createdAt: Date {
        switch self {
        case .photo(let p): return p.createdAt
        case .list(let l): return l.createdAt
        case .stack(let lead, _): return lead.createdAt
        }
    }

    var dragID: String {
        switch self {
        case .photo(let p): return "photo:\(p.uuid.uuidString)"
        case .list(let l): return "list:\(l.uuid.uuidString)"
        case .stack(let lead, _): return "photo:\(lead.uuid.uuidString)"
        }
    }
}

// MARK: - Project detail (unified reorderable list)

private struct ProjectDetailView: View {
    @Bindable var project: ProjectData
    var initialExpandedUUIDs: Set<String> = []
    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onSelectPin: ((PinnedLocationData) -> Void)?
    var onZoomToPin: ((PinnedLocationData) -> Void)?
    var onClearPin: (() -> Void)?
    var onRevealPins: (([PinnedLocationData]) -> Void)? = nil
    var onOpenCarousel: ((PinnedLocationData) -> Void)? = nil
    var onExpandedChanged: (([String]) -> Void)? = nil
    /// Set from the photo grid to scroll the sidebar to a specific pin.
    var scrollToPinUUID: UUID? = nil
    /// Set by ContentView (from M key or grid context menu) to open the move sheet
    /// for specific location UUIDs, bypassing sidebar selection.
    @Binding var externalMoveUUIDs: [UUID]

    @Environment(\.modelContext) private var modelContext
    @State private var showAddList = false
    @State private var newListName = ""
    @State private var expandedListIDs: Set<PersistentIdentifier> = []
    @State private var topLevelDropTargeted = false
    @State private var renamingList: LocationListData? = nil
    @State private var renameListText = ""
    @State private var isBackfilling = false
    @State private var showMovePopup = false
    @State private var importProgress: (current: Int, total: Int)? = nil
    @State private var timelineProgress: (current: Int, total: Int, name: String)? = nil
    // Selection lives in a reference-type model owned via plain @State (not @StateObject),
    // so changing it never re-renders this view or rebuilds the row list. Only the visible
    // rows observe it, so shift-selecting thousands of off-screen rows is instant.
    @StateObject private var selection = SidebarSelection()
    // Cached sidebar items — rebuilt only when photos/lists actually change,
    // not on every render triggered by selection or scroll state.
    @State private var cachedSidebarItems: [SidebarItem] = []
    // Held so moveSelection can scroll without needing to be inside the ScrollViewReader body.
    @State private var listProxyHolder: ScrollViewProxy? = nil

    /// Flat ordered list of every currently visible row id (including expanded list pins),
    /// used to resolve a shift-click range.
    private var flatVisibleIDs: [PersistentIdentifier] {
        var result: [PersistentIdentifier] = []
        for item in cachedSidebarItems {
            switch item {
            case .photo(let pin):
                result.append(pin.persistentModelID)
            case .list(let list):
                result.append(list.persistentModelID)
                if expandedListIDs.contains(list.persistentModelID) {
                    result.append(contentsOf:
                        list.pins.sorted { $0.sortOrder < $1.sortOrder }.map(\.persistentModelID))
                }
            case .stack(let lead, _):
                result.append(lead.persistentModelID)
            }
        }
        return result
    }

    /// Single click selects just this row (and fires the map side effect).
    /// Shift-click extends a contiguous range from the anchor.
    /// Option-click toggles this item in/out of a disparate selection.
    private func handleTap(_ id: PersistentIdentifier, shift: Bool, option: Bool = false) {
        if option {
            if selection.ids.contains(id) {
                selection.ids.remove(id)
                if selection.anchor == id { selection.anchor = selection.ids.first }
            } else {
                selection.ids.insert(id)
                selection.anchor = id
            }
            return   // disparate toggle: no map nav
        }
        if shift, let anchor = selection.anchor {
            let order = flatVisibleIDs
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                selection.ids = Set(order[min(a, b)...max(a, b)])
            } else {
                selection.ids = [id]; selection.anchor = id
            }
            return   // range select: no map nav
        }
        selection.ids = [id]
        selection.anchor = id
        if let pin = findPin(byID: id) {
            if pin.hasGPS { onSelectPin?(pin) } else { onClearPin?() }
        } else if let list = project.lists.first(where: { $0.persistentModelID == id }) {
            onClearPin?()
            onFitToList?(list.pins.filter { $0.hasGPS })
        }
    }

    /// Double-click zooms into a pin (or fits to a list). No-GPS pins open in carousel.
    private func handleDoubleTap(_ id: PersistentIdentifier) {
        if let pin = findPin(byID: id) {
            if pin.hasGPS {
                onZoomToPin?(pin)
            } else {
                onOpenCarousel?(pin)
            }
        } else if let list = project.lists.first(where: { $0.persistentModelID == id }) {
            onFitToList?(list.pins.filter { $0.hasGPS })
        }
    }

    /// Moves keyboard selection up (-1) or down (+1) through the flat visible row list.
    /// If the next item is a list, it auto-expands it and steps inside to its first pin.
    private func moveSelection(_ delta: Int) {
        let flat = flatVisibleIDs
        guard !flat.isEmpty else { return }
        let current = selection.anchor ?? flat.first!
        guard let idx = flat.firstIndex(of: current) else { return }
        var next = max(0, min(flat.count - 1, idx + delta))

        // If the target is a collapsed list and we're moving into it, expand it first
        // and step to its first pin (or last pin when moving up).
        if let list = cachedSidebarItems.compactMap({ if case .list(let l) = $0 { return l } else { return nil } })
            .first(where: { $0.persistentModelID == flat[next] }),
           !expandedListIDs.contains(list.persistentModelID) {
            let pins = list.pins.sorted { $0.sortOrder < $1.sortOrder }
            if !pins.isEmpty {
                expandedListIDs.insert(list.persistentModelID)
                // Re-compute flat after expansion to find the pin's index.
                let newFlat = flatVisibleIDs
                let targetPin = delta > 0 ? pins.first! : pins.last!
                if let pinIdx = newFlat.firstIndex(of: targetPin.persistentModelID) {
                    next = pinIdx
                }
            }
        }

        let newFlat = flatVisibleIDs
        guard next < newFlat.count else { return }
        let targetID = newFlat[next]
        selection.ids = [targetID]
        selection.anchor = targetID

        // Fire the same map / photo-mode side effects as a tap.
        if let pin = findPin(byID: targetID) {
            onSelectPin?(pin)
        }

        // .none anchor: only scrolls enough to make the row visible; doesn't re-center.
        listProxyHolder?.scrollTo(targetID, anchor: .none)
    }

    private func rebuildSidebarItems() {
        // Group imported photos by stackID; unstacked photos become individual .photo items.
        var stackGroups: [UUID: [PinnedLocationData]] = [:]
        var unstackedPhotos: [PinnedLocationData] = []
        for pin in project.importedPhotos {
            if let sid = pin.stackID {
                stackGroups[sid, default: []].append(pin)
            } else {
                unstackedPhotos.append(pin)
            }
        }
        var photoItems: [SidebarItem] = unstackedPhotos.map { .photo($0) }
        for (_, members) in stackGroups {
            let sorted = members.sorted { $0.sortOrder < $1.sortOrder }
            guard let lead = sorted.first else { continue }
            photoItems.append(.stack(lead: lead, members: sorted))
        }
        let lists = project.lists.filter { $0.parentList == nil }.map { SidebarItem.list($0) }
        cachedSidebarItems = (photoItems + lists).sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    // Use cachedSidebarItems everywhere the old sidebarItems was used.
    private var sidebarItems: [SidebarItem] { cachedSidebarItems }

    /// Assigns sequential panelOrder values. Debounced so rapid imports (200 photos)
    /// don't fire 200 consecutive full-list writes.
    private func normalizeOrder() {
        // Rebuild the display list first so it's current.
        rebuildSidebarItems()
        // Normalize panelOrder values — only write when stale to avoid cascading updates.
        for (i, item) in cachedSidebarItems.enumerated() {
            switch item {
            case .photo(let p):          if p.panelOrder != i { p.panelOrder = i }
            case .list(let l):           if l.panelOrder != i { l.panelOrder = i }
            case .stack(let lead, _):    if lead.panelOrder != i { lead.panelOrder = i }
            }
        }
    }

    /// Resolves a drag id ("photo:<uuid>" / "list:<uuid>") to its live SidebarItem.
    private func resolve(_ dragID: String) -> SidebarItem? {
        cachedSidebarItems.first { $0.dragID == dragID }
    }

    /// Finds a pin anywhere in the project — top-level or inside any list.
    private func findPin(uuid: String) -> PinnedLocationData? {
        if let p = project.importedPhotos.first(where: { $0.uuid.uuidString == uuid }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.uuid.uuidString == uuid }) { return p }
        }
        return nil
    }

    /// Removes a pin from wherever it currently lives (list or top-level).
    private func detach(_ pin: PinnedLocationData) {
        if let list = pin.list {
            list.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
            pin.list = nil
        }
        project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
        pin.owningProject = nil
    }

    // MARK: - Drop loading

    /// Loads drag payload from providers and dispatches to handleDrop on main actor.
    private func loadDrop(_ providers: [NSItemProvider], onto target: SidebarItem) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                if dragID.hasPrefix("photos:") {
                    let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                    if case .list(let list) = target {
                        let pins = uuids.compactMap { findPin(uuid: $0) }
                        pins.forEach { movePinsToList($0, intoList: list) }
                    }
                } else {
                    _ = handleDrop(dragID, onto: target)
                }
            }
        }
        return true
    }

    /// Moves a dragged item to the top/bottom of the sidebar.
    /// Handles list:, photo:, and pin: payloads.
    private func loadDropToTopLevel(_ providers: [NSItemProvider], atTop: Bool) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                // List reorder: move to top or bottom.
                if dragID.hasPrefix("list:") {
                    let uuid = String(dragID.dropFirst(5))
                    guard let list = project.lists.first(where: { $0.uuid.uuidString == uuid }) else { return }
                    list.panelOrder = atTop ? -1 : sidebarItems.count + 1
                    normalizeOrder()
                    try? modelContext.save()
                    return
                }
                // Photo reorder: move to top or bottom (when already top-level).
                if dragID.hasPrefix("photo:") {
                    let uuid = String(dragID.dropFirst(6))
                    if let pin = project.importedPhotos.first(where: { $0.uuid.uuidString == uuid }) {
                        pin.panelOrder = atTop ? -1 : sidebarItems.count + 1
                        normalizeOrder()
                        try? modelContext.save()
                        return
                    }
                }
                // Pin dragged out of a list to top/bottom.
                let uuid: String
                if dragID.hasPrefix("pin:") { uuid = String(dragID.dropFirst(4)) }
                else if dragID.hasPrefix("photo:") { uuid = String(dragID.dropFirst(6)) }
                else { return }
                guard let primaryPin = findPin(uuid: uuid) else { return }
                guard primaryPin.list != nil else { return } // already top-level, nothing to do

                // If the dragged pin is part of a multi-selection, move all selected pins.
                var pinsToMove: [PinnedLocationData] = [primaryPin]
                if selection.contains(primaryPin.persistentModelID) {
                    for id in selection.ids where id != primaryPin.persistentModelID {
                        if let p = findPin(byID: id), p.list != nil { pinsToMove.append(p) }
                    }
                }
                for pin in pinsToMove {
                    detach(pin)
                    pin.owningProject = project
                    pin.panelOrder = atTop ? -1 : sidebarItems.count + 1
                    project.importedPhotos.append(pin)
                }
                normalizeOrder()
                try? modelContext.save()
            }
        }
        return true
    }

    /// Moves `pin` and all other selected pins (if pin is in the selection) into `list`.
    private func movePinsToList(_ primaryPin: PinnedLocationData, intoList list: LocationListData, afterPin: PinnedLocationData? = nil) {
        // Collect all pins to move: the primary one plus any other selected pins.
        var allPins: [PinnedLocationData] = [primaryPin]
        if selection.contains(primaryPin.persistentModelID) {
            for id in selection.ids where id != primaryPin.persistentModelID {
                if let pin = findPin(byID: id) { allPins.append(pin) }
            }
        }
        for pin in allPins {
            guard pin.list?.persistentModelID != list.persistentModelID else { continue }
            detach(pin)
            if let after = afterPin, allPins.count == 1,
               let idx = list.pins.firstIndex(where: { $0.persistentModelID == after.persistentModelID }) {
                list.pins.insert(pin, at: idx + 1)
            } else {
                list.pins.insert(pin, at: 0)
            }
            pin.list = list
        }
        for (i, p) in list.pins.enumerated() { p.sortOrder = i }
        normalizeOrder()
        try? modelContext.save()
    }

    /// Finds a pin anywhere in the project by its PersistentIdentifier.
    private func findPin(byID id: PersistentIdentifier) -> PinnedLocationData? {
        if let p = project.importedPhotos.first(where: { $0.persistentModelID == id }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.persistentModelID == id }) { return p }
        }
        return nil
    }

    /// Loads drag payload and moves the pin into a list, optionally after a specific pin.
    private func loadDropPin(_ providers: [NSItemProvider], intoList list: LocationListData, afterPin: PinnedLocationData? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                if dragID.hasPrefix("photos:") {
                    let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                    let pins = uuids.compactMap { findPin(uuid: $0) }
                    pins.forEach { movePinsToList($0, intoList: list, afterPin: afterPin) }
                    return
                }
                let uuid: String
                if dragID.hasPrefix("pin:") { uuid = String(dragID.dropFirst(4)) }
                else if dragID.hasPrefix("photo:") { uuid = String(dragID.dropFirst(6)) }
                else { return }
                guard let pin = findPin(uuid: uuid) else { return }
                movePinsToList(pin, intoList: list, afterPin: afterPin)
            }
        }
        return true
    }

    // MARK: - Drop handling

    /// Central drop handler for top-level sidebar items.
    private func handleDrop(_ dragID: String, onto target: SidebarItem) -> Bool {
        // Pin dragged from inside a list onto a top-level target.
        if dragID.hasPrefix("pin:") {
            let uuid = String(dragID.dropFirst(4))
            guard let pin = findPin(uuid: uuid) else { return false }
            switch target {
            case .list(let list):
                // Move pin (and any other selected pins) into this list.
                if pin.list?.persistentModelID == list.persistentModelID { return false }
                movePinsToList(pin, intoList: list)
            case .photo(let targetPin):
                // Move out to top-level, placed near the target photo.
                detach(pin)
                pin.owningProject = project
                pin.panelOrder = targetPin.panelOrder
                project.importedPhotos.append(pin)
                normalizeOrder()
                try? modelContext.save()
            case .stack(let lead, _):
                detach(pin)
                pin.owningProject = project
                pin.panelOrder = lead.panelOrder
                project.importedPhotos.append(pin)
                normalizeOrder()
                try? modelContext.save()
            }
            return true
        }

        // Top-level item dragged onto another top-level item.
        guard let dragged = resolve(dragID) else { return false }
        if dragged.id == target.id { return false }

        // Top-level photo dragged onto a list → move into list (with multi-select support).
        if case .photo(let pin) = dragged, case .list(let list) = target {
            movePinsToList(pin, intoList: list)
            return true
        }

        // Otherwise reorder.
        reorder(dragged, before: target)
        return true
    }

    /// Reorders `dragged` next to `target`. Inserts before target when moving up,
    /// after target when moving down, so every slot is reachable.
    private func reorder(_ dragged: SidebarItem, before target: SidebarItem) {
        var items = sidebarItems
        guard let from = items.firstIndex(where: { $0.id == dragged.id }) else { return }
        let moving = items.remove(at: from)
        guard var to = items.firstIndex(where: { $0.id == target.id }) else { return }
        // When dragging downward, insert after the target so the item lands below it.
        if from > to { to += 1 }
        items.insert(moving, at: min(to, items.count))
        for (i, item) in items.enumerated() {
            switch item {
            case .photo(let p):       p.panelOrder = i
            case .list(let l):        l.panelOrder = i
            case .stack(let lead, _): lead.panelOrder = i
            }
        }
        try? modelContext.save()
    }

    /// Deletes a single pin, whether it's a top-level photo or lives inside a list.
    private func deletePin(_ pin: PinnedLocationData) {
        if let list = pin.list {
            list.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
        } else {
            project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
        }
        modelContext.delete(pin)
        normalizeOrder()
        try? modelContext.save()
    }

    /// Deletes every currently-selected sidebar item — top-level photos, pins inside
    /// lists, and whole lists alike. Resolves all targets first, then deletes, so we never
    /// re-read a relationship mid-mutation.
    private func deleteSelectedItems() {
        let ids = selection.ids
        guard !ids.isEmpty else { return }
        var pinsToDelete: [PinnedLocationData] = []
        var listsToDelete: [LocationListData] = []
        for id in ids {
            if let pin = findPin(byID: id) {
                pinsToDelete.append(pin)
            } else if let list = project.lists.first(where: { $0.persistentModelID == id }) {
                listsToDelete.append(list)
            }
        }
        for pin in pinsToDelete {
            if let list = pin.list {
                list.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
            } else {
                project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
            }
            modelContext.delete(pin)
        }
        for list in listsToDelete {
            activeListIDs.remove(list.persistentModelID)
            modelContext.delete(list)
        }
        selection.ids = []
        normalizeOrder()
        try? modelContext.save()
    }

    /// True when `id` is part of a multi-item selection (used to switch context-menu
    /// actions and labels between single-item and whole-selection delete).
    private func isInMultiSelection(_ id: PersistentIdentifier) -> Bool {
        selection.ids.count > 1 && selection.ids.contains(id)
    }

    /// "Delete Photos (3)" when the selection is all photos/pins, else "Delete Items (3)".
    private var deleteSelectionLabel: String {
        let allPhotos = selection.ids.allSatisfy { findPin(byID: $0) != nil }
        return allPhotos ? "Delete Photos (\(selection.ids.count))"
                         : "Delete Items (\(selection.ids.count))"
    }

    private var selectedPhotoCount: Int {
        selection.ids.filter { findPin(byID: $0) != nil }.count
    }

    /// Groups selected top-level photos into a stack (shared stackID).
    private func makeStack(from ids: Set<PersistentIdentifier>) {
        let pins = ids.compactMap { findPin(byID: $0) }
        guard pins.count >= 2 else { return }
        let stackID = UUID()
        for pin in pins { pin.stackID = stackID }
        selection.ids = []
        normalizeOrder()
        try? modelContext.save()
    }

    /// Removes all pins from their stack (clears stackID).
    private func unstackPins(_ pins: [PinnedLocationData]) {
        for pin in pins { pin.stackID = nil }
        normalizeOrder()
        try? modelContext.save()
    }

    var body: some View {
        ScrollViewReader { listProxy in
        let _ = { listProxyHolder = listProxy }()
        List {
            Color.clear.frame(height: sidebarTopPadding).listRowBackground(Color.clear)

            // Drop zone: drag any list pin here to move it to the top-level project.
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.up")
                    .font(.caption)
                Text("Drop here to remove from list")
                    .font(.caption)
            }
            .foregroundStyle(topLevelDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(topLevelDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .padding(.horizontal, 4)
            )
            .listRowBackground(Color.clear)
            .onDrop(of: [.text, .fileURL, .image], isTargeted: $topLevelDropTargeted) { providers in
                tryImportDrop(providers, into: nil) || loadDropToTopLevel(providers, atTop: true)
            }

            ForEach(sidebarItems) { item in
                switch item {
                case .photo(let pin):
                    PinRow(
                        pin: pin,
                        isSelected: selection.contains(pin.persistentModelID),
                        onTap: { shift, option in handleTap(pin.persistentModelID, shift: shift, option: option) },
                        onDoubleTap: { handleDoubleTap(pin.persistentModelID) }
                    )
                    .contextMenu {
                        let multi = isInMultiSelection(pin.persistentModelID)
                        if multi && selectedPhotoCount >= 2 {
                            Button { makeStack(from: selection.ids) } label: {
                                Label("Make Stack", systemImage: "square.3.layers.3d")
                            }
                            Divider()
                        }
                        if let path = pin.originalFilePath {
                            Button { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Divider()
                        }
                        Button(role: .destructive) {
                            if multi { deleteSelectedItems() } else { deletePin(pin) }
                        } label: {
                            Label(multi ? deleteSelectionLabel : "Delete Photo", systemImage: "trash")
                        }
                    }
                    .onDrag { NSItemProvider(object: item.dragID as NSString) }
                    .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                        tryImportDrop(providers, into: nil) || loadDrop(providers, onto: .photo(pin))
                    }
                case .stack(let lead, let members):
                    StackRow(
                        lead: lead,
                        members: members,
                        isSelected: selection.contains(lead.persistentModelID),
                        onTap: { shift, option in handleTap(lead.persistentModelID, shift: shift, option: option) },
                        onDoubleTap: { onOpenCarousel?(lead) }
                    )
                    .contextMenu {
                        Button { unstackPins(members) } label: {
                            Label("Unstack", systemImage: "square.3.layers.3d.slash")
                        }
                        Divider()
                        Button(role: .destructive) {
                            members.forEach { deletePin($0) }
                        } label: {
                            Label("Delete Stack", systemImage: "trash")
                        }
                    }
                    .onDrag { NSItemProvider(object: item.dragID as NSString) }
                    .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                        tryImportDrop(providers, into: nil) || loadDrop(providers, onto: .stack(lead: lead, members: members))
                    }
                case .list(let list):
                    let isExpanded = expandedListIDs.contains(list.persistentModelID)
                    ListRow(
                        list: list,
                        isExpanded: isExpanded,
                        isSelected: selection.contains(list.persistentModelID),
                        onToggleExpand: {
                            if isExpanded { expandedListIDs.remove(list.persistentModelID) }
                            else { expandedListIDs.insert(list.persistentModelID) }
                        },
                        onTap: { shift, option in handleTap(list.persistentModelID, shift: shift, option: option) },
                        onDoubleTap: { handleDoubleTap(list.persistentModelID) },
                        activeListIDs: $activeListIDs,
                        onFitToList: onFitToList,
                        onRename: {
                            renameListText = list.name
                            renamingList = list
                        },
                        onToggleAllVisibility: { makeAllActive in
                            if makeAllActive {
                                project.lists.forEach { activeListIDs.insert($0.persistentModelID) }
                            } else {
                                project.lists.forEach { activeListIDs.remove($0.persistentModelID) }
                            }
                        },
                        dragProvider: { NSItemProvider(object: item.dragID as NSString) }
                    )
                    .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                        tryImportDrop(providers, into: list) || loadDrop(providers, onto: .list(list))
                    }

                    if isExpanded {
                        let pins = list.pins.sorted { $0.sortOrder < $1.sortOrder }
                        ForEach(pins) { pin in
                            PinRow(
                                pin: pin,
                                isSelected: selection.contains(pin.persistentModelID),
                                listColor: Color(hexString: list.colorHex),
                                onTap: { shift, option in handleTap(pin.persistentModelID, shift: shift, option: option) },
                                onDoubleTap: { handleDoubleTap(pin.persistentModelID) }
                            )
                            .padding(.leading, 24)
                            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
                            .contextMenu {
                                let multi = isInMultiSelection(pin.persistentModelID)
                                if multi && selectedPhotoCount >= 2 {
                                    Button { makeStack(from: selection.ids) } label: {
                                        Label("Make Stack", systemImage: "square.3.layers.3d")
                                    }
                                    Divider()
                                }
                                Button(role: .destructive) {
                                    if multi { deleteSelectedItems() } else { deletePin(pin) }
                                } label: {
                                    Label(multi ? deleteSelectionLabel : "Delete Photo", systemImage: "trash")
                                }
                            }
                            .onDrag { NSItemProvider(object: "pin:\(pin.uuid.uuidString)" as NSString) }
                            .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                                tryImportDrop(providers, into: list) || loadDropPin(providers, intoList: list, afterPin: pin)
                            }
                        }
                    }
                }
            }

            // Bottom drop zone — same as the top one, for when the list is scrolled down.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .listRowBackground(Color.clear)
                .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                    tryImportDrop(providers, into: nil) || loadDropToTopLevel(providers, atTop: false)
                }
        }
        .onAppear {
            normalizeOrder()
            // project.lists is synchronously available here via SwiftData.
            if !initialExpandedUUIDs.isEmpty {
                expandedListIDs = Set(
                    project.lists.filter { initialExpandedUUIDs.contains($0.uuid.uuidString) }
                                 .map(\.persistentModelID)
                )
            }
        }
        // Delete key removes the current selection. A hidden keyboard-shortcut button is
        // used instead of `.onDeleteCommand` because the latter makes the List a focus
        // sink on macOS, which blocks click-to-focus on TextFields elsewhere in the window
        // (e.g. the Google Maps search box). The actions no-op on an empty selection, and a
        // focused TextField consumes the key itself, so these never interfere with typing.
        .background {
            Button("", action: deleteSelectedItems)
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            Button("") { selection.ids = []; selection.anchor = nil }
                .keyboardShortcut("a", modifiers: .shift)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onChange(of: project.importedPhotos.count) { normalizeOrder() }
        .onChange(of: project.lists.count) { normalizeOrder() }
        .onChange(of: expandedListIDs) { _, ids in
            // Persist current expanded state as UUID strings (stable across relaunches).
            let uuids = project.lists
                .filter { ids.contains($0.persistentModelID) }
                .map(\.uuid.uuidString)
            onExpandedChanged?(uuids)
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newListName = ""
                        showAddList = true
                    } label: {
                        Label("New List", systemImage: "list.bullet")
                    }
                    Button { importPhotos() } label: {
                        Label("Import Photos", systemImage: "photo.badge.plus")
                    }
                    Divider()
                    Button { pickTimelineAndBackfill() } label: {
                        Label(isBackfilling ? "Importing Timeline…" : "Import Google Maps Timeline",
                              systemImage: "location.circle")
                    }
                    .disabled(isBackfilling)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("Rename List", isPresented: Binding(
            get: { renamingList != nil },
            set: { if !$0 { renamingList = nil } }
        )) {
            TextField("List name", text: $renameListText)
            Button("Rename") {
                if let list = renamingList, !renameListText.trimmingCharacters(in: .whitespaces).isEmpty {
                    list.name = renameListText.trimmingCharacters(in: .whitespaces)
                    try? modelContext.save()
                }
                renamingList = nil
            }
            Button("Cancel", role: .cancel) { renamingList = nil }
        }
        .sheet(isPresented: $showAddList) {
            NameEntrySheet(
                title: "New List in \(project.name)",
                placeholder: "List name",
                text: $newListName,
                onDismiss: { showAddList = false }
            ) { name in
                let colorHex = LocationListData.palette[project.lists.count % LocationListData.palette.count]
                let list = LocationListData(name: name, colorHex: colorHex)
                // Shift every existing item down to make room at the top.
                for existing in project.lists { existing.panelOrder += 1 }
                project.importedPhotos.forEach { $0.panelOrder += 1 }
                list.panelOrder = 0
                modelContext.insert(list)
                list.project = project
                project.lists.append(list)
                try? modelContext.save()
                showAddList = false
            }
        }
        .onChange(of: scrollToPinUUID) { _, uuid in
            guard let uuid,
                  let pin = findPin(uuid: uuid.uuidString) else { return }
            // Expand the containing list first so its pins are in the List hierarchy.
            if let list = pin.list {
                expandedListIDs.insert(list.persistentModelID)
            }
            // Wait long enough for SwiftUI to insert the newly-expanded rows before scrolling.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    listProxy.scrollTo(pin.persistentModelID, anchor: .none)
                }
                selection.ids = [pin.persistentModelID]
                selection.anchor = pin.persistentModelID
            }
        }
        } // ScrollViewReader
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow)   { moveSelection(-1); return .handled }
        // Hidden M key button — opens Move popup when sidebar pins are selected.
        .background {
            Button("") {
                let hasPins = selection.ids.contains(where: { findPin(byID: $0) != nil })
                if hasPins { showMovePopup = true }
            }
            .keyboardShortcut("m", modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
        }
        // External trigger from ContentView (M key while grid is focused, or grid context menu).
        .onChange(of: externalMoveUUIDs) { _, uuids in
            if !uuids.isEmpty { showMovePopup = true }
        }
        .sheet(isPresented: $showMovePopup, onDismiss: { externalMoveUUIDs = [] }) {
            let moveIDs: [UUID] = {
                // Prefer externally-supplied UUIDs (grid/map selection); fall back to sidebar.
                let ext = externalMoveUUIDs
                if !ext.isEmpty { return ext }
                return selection.ids.compactMap { findPin(byID: $0)?.uuid }
            }()
            MoveToListSheet(
                lists: project.lists,
                onMove: { list in
                    let pins = moveIDs.compactMap { uuid in
                        project.lists.flatMap(\.pins).first(where: { $0.uuid == uuid })
                        ?? project.importedPhotos.first(where: { $0.uuid == uuid })
                    }
                    pins.forEach { movePinsToList($0, intoList: list) }
                    showMovePopup = false
                    externalMoveUUIDs = []
                },
                onDismiss: { showMovePopup = false; externalMoveUUIDs = [] }
            )
        }
        .overlay {
            if let prog = importProgress {
                ImportProgressOverlay(current: prog.current, total: prog.total)
            } else if let prog = timelineProgress {
                TimelineProgressOverlay(current: prog.current, total: prog.total, currentName: prog.name)
            }
        }
    }

    private func importPhotos() {
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
    }

    /// Picks a Google Maps Timeline JSON export and backfills GPS onto photos that lack it
    /// by matching their EXIF capture time to the timeline's locations.
    private func pickTimelineAndBackfill() {
        let panel = NSOpenPanel()
        panel.title = "Select Google Maps Timeline JSON"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBackfilling = true
        timelineProgress = (0, 0, "")
        DebugLogger.shared.log("Timeline import started…", level: .info)
        let context = modelContext
        Task {
            let result = await TimelineGeoService.backfill(timelineURL: url, context: context) { current, total, name in
                timelineProgress = (current, total, name)
            }
            isBackfilling = false
            timelineProgress = nil
            DebugLogger.shared.log(
                "Timeline import done — timezone: \(result.detectedTimezone), updated: \(result.updated), skipped: \(result.skipped), failed: \(result.failed)",
                level: result.failed > 0 ? .warning : .success
            )
            if !result.updatedPins.isEmpty {
                onRevealPins?(result.updatedPins)
            }
        }
    }

    /// Imports photo files into a list (or top-level when `list` is nil), inserting the
    /// pins and wiring their relationship. Shared by the Import menu and Finder drag-drop.
    @MainActor
    private func importImageURLs(_ urls: [URL], into list: LocationListData?) async {
        // Collect all existing pins across this project for duplicate detection.
        let existingPins = (project.lists.flatMap(\.pins)) + project.importedPhotos
        importProgress = (0, urls.count)
        let results = await PhotoImportService.importPhotos(from: urls, into: list,
                                                            existingPins: existingPins) { current, total in
            importProgress = (current, total)
        }
        importProgress = nil
        if let list {
            for result in results {
                modelContext.insert(result.pin)
                result.pin.list = list
            }
        } else {
            var nextOrder = sidebarItems.count
            for result in results {
                result.pin.panelOrder = nextOrder
                nextOrder += 1
                modelContext.insert(result.pin)
                project.importedPhotos.append(result.pin)
            }
        }
        normalizeOrder()
        try? modelContext.save()
    }

    /// If `providers` carry Finder image files, kicks off an import into `list`
    /// (top-level when nil) and returns true. Returns false for internal reorder drags
    /// (plain-text drag ids), so the caller can fall back to its move/reorder handler.
    private func tryImportDrop(_ providers: [NSItemProvider], into list: LocationListData?) -> Bool {
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

// MARK: - List row (expand in place to see pins)

private struct ListRow: View {
    let list: LocationListData
    let isExpanded: Bool
    var isSelected: Bool = false
    let onToggleExpand: () -> Void
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onRename: (() -> Void)? = nil
    /// Called when the user Option+clicks the eye. `true` = show all, `false` = hide all.
    var onToggleAllVisibility: ((Bool) -> Void)? = nil
    /// Supply a drag provider to make the name area a drag handle. Buttons are
    /// excluded so accidental drag on chevron/eye never triggers a reorder.
    var dragProvider: (() -> NSItemProvider)? = nil
    @Environment(\.modelContext) private var modelContext

    private var isActive: Bool { activeListIDs.contains(list.persistentModelID) }
    private var listColor: Color { Color(hexString: list.colorHex) }

    var body: some View {
        HStack(spacing: 6) {
            // Chevron and eye are Buttons so clicking them toggles expand/visibility
            // without selecting the row.
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Drag handle: only this region initiates a reorder drag, keeping the
            // chevron and eye buttons free from accidental drag triggers.
            HStack(spacing: 6) {
                Circle()
                    .fill(listColor)
                    .frame(width: 10, height: 10)
                Text(list.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                if !list.pins.isEmpty {
                    Text("\(list.pins.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .modifier(OptionalDrag(provider: dragProvider))

            Button {
                let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) == true
                if optionHeld, let toggle = onToggleAllVisibility {
                    // Option+click: show all when this one is hidden, hide all when visible.
                    toggle(!isActive)
                } else {
                    if isActive { activeListIDs.remove(list.persistentModelID) }
                    else { activeListIDs.insert(list.persistentModelID) }
                }
            } label: {
                Image(systemName: isActive ? "eye.fill" : "eye")
                    .foregroundStyle(isActive ? listColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(onToggleAllVisibility != nil ? "Click to toggle · Option+click to toggle all" : "")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .onTapGesture { onTap?(NSEvent.modifierFlags.contains(.shift), NSEvent.modifierFlags.contains(.option)) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        .contextMenu {
            Button { onRename?() } label: {
                Label("Rename List", systemImage: "pencil")
            }
            if let onFitToList {
                Button {
                    onFitToList(list.pins.filter { $0.hasGPS })
                } label: {
                    Label("Fit Map to List", systemImage: "mappin.and.ellipse")
                }
            }
            Divider()
            Button(role: .destructive) {
                activeListIDs.remove(list.persistentModelID)
                modelContext.delete(list)
                try? modelContext.save()
            } label: {
                Label("Delete List", systemImage: "trash")
            }
        }
    }
}

/// Applies `.onDrag` only when a provider is supplied, letting call sites restrict
/// dragging to a specific sub-region while leaving button areas drag-free.
private struct OptionalDrag: ViewModifier {
    let provider: (() -> NSItemProvider)?
    func body(content: Content) -> some View {
        if let provider {
            content.onDrag(provider)
        } else {
            content
        }
    }
}

// MARK: - Pin row (shared by photos and list pins)

private struct PinRow: View {
    let pin: PinnedLocationData
    var isSelected: Bool = false
    var listColor: Color? = nil
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(listColor ?? .clear, lineWidth: 2)
                )
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 3) {
                Text(pin.name)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !pin.hasGPS {
                    Label("No GPS", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        // Single click selects (instant); double click zooms. Manual handling — no native
        // List selection — so selecting thousands is an O(1) set write with no per-row work.
        .onTapGesture { onTap?(NSEvent.modifierFlags.contains(.shift), NSEvent.modifierFlags.contains(.option)) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        .contextMenu {
            if let path = pin.originalFilePath {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let url: URL? = pin.thumbnailImages.first?.url
            ?? pin.photoFiles.first.map { PinPhotoStore.fileURL($0) }
            ?? pin.imageURL.flatMap { URL(string: $0) }
        if let url {
            // GooglePhotoImage uses PhotoLoader's shared NSCache — thumbnails are decoded
            // once and reused on scroll, unlike AsyncImage which has no cache.
            GooglePhotoImage(url: url) {
                Color.secondary.opacity(0.2)
            }
            .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mappin").foregroundStyle(.secondary))
        }
    }
}

// MARK: - Stack row

private struct StackRow: View {
    let lead: PinnedLocationData
    let members: [PinnedLocationData]
    var isSelected: Bool = false
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                thumbnailImage(for: lead)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                // Stacked layers badge
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.ultraThinMaterial)
                    Text("\(members.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .frame(width: 20, height: 16)
                .offset(x: 4, y: 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(lead.name)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(members.count) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .onTapGesture { onTap?(NSEvent.modifierFlags.contains(.shift), NSEvent.modifierFlags.contains(.option)) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
    }

    @ViewBuilder
    private func thumbnailImage(for pin: PinnedLocationData) -> some View {
        let url: URL? = pin.thumbnailImages.first?.url
            ?? pin.photoFiles.first.map { PinPhotoStore.fileURL($0) }
            ?? pin.imageURL.flatMap { URL(string: $0) }
        if let url {
            GooglePhotoImage(url: url) { Color.secondary.opacity(0.2) }
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary))
        }
    }
}

// MARK: - OutlineGroup children helper

extension LocationListData {
    var sortedChildren: [LocationListData]? {
        let children = childLists.sorted { $0.sortOrder < $1.sortOrder }
        return children.isEmpty ? nil : children
    }
}

// MARK: - Name entry sheet

struct NameEntrySheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onDismiss: () -> Void
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !text.isEmpty { onConfirm(text) } }
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Create") { onConfirm(text) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

// MARK: - Import progress overlay

private struct ImportProgressOverlay: View {
    let current: Int
    let total: Int

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(current) / Double(total), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Importing Photos…")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 200)
            Text("\(current) of \(total)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }
}

// MARK: - Timeline progress overlay

private struct TimelineProgressOverlay: View {
    let current: Int
    let total: Int
    let currentName: String

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(current) / Double(total), 1)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("Setting Photo Locations")
                .font(.subheadline.weight(.semibold))
            Text("Matching photos to Timeline history…")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 200)
            if !currentName.isEmpty {
                Text(currentName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(width: 200)
            }
            if total > 0 {
                Text("\(current) of \(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 12)
    }
}

// MARK: - Move-to-list popup

private struct MoveToListSheet: View {
    let lists: [LocationListData]
    let onMove: (LocationListData) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var filtered: [LocationListData] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return lists }
        return lists.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.square")
                    .foregroundStyle(.secondary)
                TextField("Move to list…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Filtered list
            if filtered.isEmpty {
                Text("No matching lists")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.persistentModelID) { idx, list in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hexString: list.colorHex))
                                        .frame(width: 9, height: 9)
                                    Text(list.name)
                                        .font(.subheadline)
                                    Spacer()
                                    if idx == highlighted {
                                        Image(systemName: "return")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(idx == highlighted ? Color.accentColor.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { onMove(list) }
                                .id(idx)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: highlighted) { _, idx in
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { fieldFocused = true; highlighted = 0 }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow)  { move( 1); return .handled }
        .onKeyPress(.upArrow)    { move(-1); return .handled }
        .onKeyPress(.escape)     { onDismiss(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        highlighted = (highlighted + delta + filtered.count) % filtered.count
    }

    private func commit() {
        guard highlighted < filtered.count else { return }
        onMove(filtered[highlighted])
    }
}

// MARK: - Previews

#Preview("Projects list") {
    ProjectsPanel(activeListIDs: .constant([]), externalMoveUUIDs: .constant([]))
        .frame(width: 280, height: 600)
        .modelContainer(for: [ProjectData.self, LocationListData.self, PinnedLocationData.self], inMemory: true)
}

// MARK: - Hex color helper

extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0xFF6B35
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
