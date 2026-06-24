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
    var onClearPin: (() -> Void)? = nil

    /// Persisted open project (stored as UUID string, resolved to ProjectData on load).
    @AppStorage("nav.openProjectUUID") private var openProjectUUID: String = ""
    /// Persisted expanded list UUIDs, comma-separated.
    @AppStorage("nav.expandedListUUIDs") private var expandedListUUIDs: String = ""

    @State private var navPath: [ProjectData] = []
    @State private var showAddProject = false
    @State private var newProjectName = ""

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
                        onClearPin: onClearPin,
                        onExpandedChanged: { uuids in
                            expandedListUUIDs = uuids.joined(separator: ",")
                        }
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
    }
}

// MARK: - Sidebar item (unified photo + list)

private enum SidebarItem: Identifiable {
    case photo(PinnedLocationData)
    case list(LocationListData)

    var id: PersistentIdentifier {
        switch self {
        case .photo(let p): return p.persistentModelID
        case .list(let l): return l.persistentModelID
        }
    }

    var panelOrder: Int {
        switch self {
        case .photo(let p): return p.panelOrder
        case .list(let l): return l.panelOrder
        }
    }

    var createdAt: Date {
        switch self {
        case .photo(let p): return p.createdAt
        case .list(let l): return l.createdAt
        }
    }

    /// Stable drag identifier: "photo:<uuid>" or "list:<uuid>". Transferred as a
    /// plain String, which round-trips through the pasteboard with no UTType setup.
    var dragID: String {
        switch self {
        case .photo(let p): return "photo:\(p.uuid.uuidString)"
        case .list(let l): return "list:\(l.uuid.uuidString)"
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
    var onClearPin: (() -> Void)?
    var onExpandedChanged: (([String]) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var showAddList = false
    @State private var newListName = ""
    @State private var expandedListIDs: Set<PersistentIdentifier> = []
    @State private var topLevelDropTargeted = false
    @State private var selectedItemIDs: Set<PersistentIdentifier> = []
    @State private var anchorItemID: PersistentIdentifier? = nil

    /// Flat ordered list of all currently visible item IDs, including expanded list pins.
    private var flatVisibleIDs: [PersistentIdentifier] {
        var result: [PersistentIdentifier] = []
        for item in sidebarItems {
            switch item {
            case .photo(let pin):
                result.append(pin.persistentModelID)
            case .list(let list):
                result.append(list.persistentModelID)
                if expandedListIDs.contains(list.persistentModelID) {
                    result.append(contentsOf:
                        list.pins.sorted { $0.sortOrder < $1.sortOrder }.map(\.persistentModelID)
                    )
                }
            }
        }
        return result
    }

    /// Central selection handler. Shift-click extends the range from the anchor;
    /// plain click sets a new single selection and updates the anchor.
    private func select(_ id: PersistentIdentifier, isShift: Bool,
                        mapAction: (() -> Void)? = nil) {
        if isShift, let anchor = anchorItemID {
            let flat = flatVisibleIDs
            if let a = flat.firstIndex(of: anchor), let b = flat.firstIndex(of: id) {
                selectedItemIDs = Set(flat[min(a,b)...max(a,b)])
            }
            // Range select: don't move map
        } else {
            selectedItemIDs = [id]
            anchorItemID = id
            mapAction?()
        }
    }

    private var sidebarItems: [SidebarItem] {
        let photos = project.importedPhotos.map { SidebarItem.photo($0) }
        let lists = project.lists.filter { $0.parentList == nil }.map { SidebarItem.list($0) }
        // Use createdAt as a stable tiebreaker so equal panelOrder values don't shuffle.
        return (photos + lists).sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    /// Assigns sequential panelOrder values based on the current stable sort.
    /// Call on appear and whenever the item count changes to fix any gaps or duplicates.
    private func normalizeOrder() {
        for (i, item) in sidebarItems.enumerated() {
            switch item {
            case .photo(let p): if p.panelOrder != i { p.panelOrder = i }
            case .list(let l): if l.panelOrder != i { l.panelOrder = i }
            }
        }
    }

    /// Resolves a drag id ("photo:<uuid>" / "list:<uuid>") to its live SidebarItem.
    private func resolve(_ dragID: String) -> SidebarItem? {
        sidebarItems.first { $0.dragID == dragID }
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
            Task { @MainActor in _ = handleDrop(dragID, onto: target) }
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
                guard let pin = findPin(uuid: uuid) else { return }
                guard pin.list != nil else { return } // already top-level, nothing to do
                detach(pin)
                pin.owningProject = project
                // Set panelOrder outside the current range so normalizeOrder places it correctly.
                pin.panelOrder = atTop ? -1 : sidebarItems.count + 1
                project.importedPhotos.append(pin)
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
        if selectedItemIDs.contains(primaryPin.persistentModelID) {
            for id in selectedItemIDs where id != primaryPin.persistentModelID {
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
                list.pins.append(pin)
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
            case .photo(let p): p.panelOrder = i
            case .list(let l): l.panelOrder = i
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
        let ids = selectedItemIDs
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
        selectedItemIDs = []
        anchorItemID = nil
        normalizeOrder()
        try? modelContext.save()
    }

    /// True when `id` is part of a multi-item selection (used to switch context-menu
    /// actions and labels between single-item and whole-selection delete).
    private func isInMultiSelection(_ id: PersistentIdentifier) -> Bool {
        selectedItemIDs.count > 1 && selectedItemIDs.contains(id)
    }

    /// "Delete Photos (3)" when the selection is all photos/pins, else "Delete Items (3)".
    private var deleteSelectionLabel: String {
        let allPhotos = selectedItemIDs.allSatisfy { findPin(byID: $0) != nil }
        return allPhotos ? "Delete Photos (\(selectedItemIDs.count))"
                         : "Delete Items (\(selectedItemIDs.count))"
    }

    var body: some View {
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
                        isSelected: selectedItemIDs.contains(pin.persistentModelID),
                        onSelectPin: { p in
                            let isShift = NSEvent.modifierFlags.contains(.shift)
                            select(p.persistentModelID, isShift: isShift, mapAction: {
                                if p.hasGPS { onSelectPin?(p) } else { onClearPin?() }
                            })
                        }
                    )
                    .contextMenu {
                        let multi = isInMultiSelection(pin.persistentModelID)
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
                case .list(let list):
                    let isExpanded = expandedListIDs.contains(list.persistentModelID)
                    ListRow(
                        list: list,
                        isExpanded: isExpanded,
                        isSelected: selectedItemIDs.contains(list.persistentModelID),
                        onToggleExpand: {
                            if isExpanded { expandedListIDs.remove(list.persistentModelID) }
                            else { expandedListIDs.insert(list.persistentModelID) }
                        },
                        onSelect: {
                            let isShift = NSEvent.modifierFlags.contains(.shift)
                            select(list.persistentModelID, isShift: isShift, mapAction: { onClearPin?() })
                        },
                        activeListIDs: $activeListIDs,
                        onFitToList: onFitToList,
                        onSelectPin: onSelectPin
                    )
                    .onDrag { NSItemProvider(object: item.dragID as NSString) }
                    .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                        tryImportDrop(providers, into: list) || loadDrop(providers, onto: .list(list))
                    }

                    if isExpanded {
                        let pins = list.pins.sorted { $0.sortOrder < $1.sortOrder }
                        ForEach(pins) { pin in
                            PinRow(
                                pin: pin,
                                isSelected: selectedItemIDs.contains(pin.persistentModelID),
                                listColor: Color(hexString: list.colorHex),
                                onSelectPin: { p in
                                    let isShift = NSEvent.modifierFlags.contains(.shift)
                                    select(p.persistentModelID, isShift: isShift, mapAction: {
                                        if p.hasGPS { onSelectPin?(p) } else { onClearPin?() }
                                    })
                                }
                            )
                            .padding(.leading, 24)
                            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
                            .contextMenu {
                                let multi = isInMultiSelection(pin.persistentModelID)
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
        // (e.g. the Google Maps search box). Disabled when nothing is selected so it never
        // swallows Backspace; a focused TextField consumes Backspace itself anyway.
        .background {
            Button("", action: deleteSelectedItems)
                .keyboardShortcut(.delete, modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
                .disabled(selectedItemIDs.isEmpty)
            Button("") { selectedItemIDs = [] }
                .keyboardShortcut("a", modifiers: .shift)
                .opacity(0)
                .allowsHitTesting(false)
                .disabled(selectedItemIDs.isEmpty)
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
                } label: {
                    Image(systemName: "plus")
                }
            }
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
                list.panelOrder = sidebarItems.count
                modelContext.insert(list)
                list.project = project
                project.lists.append(list)
                try? modelContext.save()
                showAddList = false
            }
        }
    }

    private func importPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in await importImageURLs(urls, into: nil) }
    }

    /// Imports photo files into a list (or top-level when `list` is nil), inserting the
    /// pins and wiring their relationship. Shared by the Import menu and Finder drag-drop.
    @MainActor
    private func importImageURLs(_ urls: [URL], into list: LocationListData?) async {
        let results = await PhotoImportService.importPhotos(from: urls, into: list)
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
    var onSelect: (() -> Void)? = nil
    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onSelectPin: ((PinnedLocationData) -> Void)?
    @Environment(\.modelContext) private var modelContext

    private var isActive: Bool { activeListIDs.contains(list.persistentModelID) }
    private var listColor: Color { Color(hexString: list.colorHex) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onSelect?()
                onFitToList?(list.pins.filter { $0.hasGPS })
            } label: {
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
            }
            .buttonStyle(.plain)
            Button {
                if isActive { activeListIDs.remove(list.persistentModelID) }
                else { activeListIDs.insert(list.persistentModelID) }
            } label: {
                Image(systemName: isActive ? "eye.fill" : "eye")
                    .foregroundStyle(isActive ? listColor : .secondary)
            }
            .buttonStyle(.plain)
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
        .contextMenu {
            Button {
                if isActive { activeListIDs.remove(list.persistentModelID) }
                else { activeListIDs.insert(list.persistentModelID) }
            } label: {
                Label(isActive ? "Hide on Map" : "Show on Map", systemImage: isActive ? "eye.slash" : "eye")
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

// MARK: - Pin row (shared by photos and list pins)

private struct PinRow: View {
    let pin: PinnedLocationData
    var isSelected: Bool = false
    var listColor: Color? = nil
    var onSelectPin: ((PinnedLocationData) -> Void)?

    var body: some View {
        Button {
            onSelectPin?(pin)
        } label: {
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
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let filename = pin.photoFiles.first {
            AsyncImage(url: PinPhotoStore.fileURL(filename)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
        } else if let urlString = pin.imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "mappin")
                        .foregroundStyle(.secondary)
                )
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

// MARK: - Previews

#Preview("Projects list") {
    ProjectsPanel(activeListIDs: .constant([]))
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
