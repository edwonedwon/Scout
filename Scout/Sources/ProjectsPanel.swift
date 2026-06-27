import SwiftUI
import SwiftData
import ScoutKit
import CoreLocation
import UniformTypeIdentifiers

#if os(macOS)
/// Snapshots the modifier keys held at the instant of each left/right mouse-DOWN.
///
/// Why this exists: SwiftUI tap gestures fire on mouse-UP and are often DEFERRED (e.g. to
/// disambiguate a possible double-tap). Reading the live global `NSEvent.modifierFlags` inside
/// a tap handler therefore reads the state at an unpredictable later moment — if the user has
/// released Shift/Option by then (which happens constantly with quick modifier-clicks), the
/// click is misread as a plain click. That silently broke option/shift multi-select in the
/// photo grid. A local mouse-DOWN monitor records the flags at the exact moment of the press,
/// so tap handlers read what was actually held during the click — deterministically.
final class ClickModifiers {
    static let shared = ClickModifiers()
    private(set) var shift = false
    private(set) var option = false
    private var monitor: Any?

    /// Installs the global-to-app local monitor once. Safe to call repeatedly.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.shift = event.modifierFlags.contains(.shift)
            self?.option = event.modifierFlags.contains(.option)
            return event   // pass the event through unchanged
        }
    }
}
#endif

/// Keyboard modifiers held during the most recent mouse-down — the correct thing to read in a
/// (possibly deferred) tap handler. iOS has no equivalent during a tap, so both are false.
func currentModifierFlags() -> (shift: Bool, option: Bool) {
    #if os(macOS)
    return (ClickModifiers.shared.shift, ClickModifiers.shared.option)
    #else
    return (false, false)
    #endif
}

/// What the user is currently dragging, set at drag start. Lets the sidebar drop delegate decide
/// whether a "between" (before/after) drop is meaningful: a PHOTO dropped on a list can only go
/// INTO it (no insertion line), whereas a LIST can be reordered before/after another list.
enum SidebarDragKind { case photo, list }
final class SidebarDragState {
    static let shared = SidebarDragState()
    /// Defaults to `.list` so behavior is unchanged unless a photo drag explicitly sets `.photo`.
    var kind: SidebarDragKind = .list
}

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
private let sidebarTopPadding: CGFloat = 55

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
    @Query(filter: #Predicate<ProjectData> { $0.deletedAt == nil },
           sort: \ProjectData.createdAt) private var projects: [ProjectData]
    @Query(filter: #Predicate<ProjectData> { $0.deletedAt != nil },
           sort: \ProjectData.createdAt) private var trashedProjects: [ProjectData]

    /// THE shared selection store (sidebar + grid + map), owned by ContentView.
    var selection: SelectionStore
    @Binding var activeListIDs: Set<PersistentIdentifier>
    /// Projects whose uncategorized (loose) photos are hidden from map + grid.
    @Binding var hiddenUncategorizedProjectIDs: Set<PersistentIdentifier>
    /// Toggled by the debug "Clear Old Lists" button. Flipping it runs the full purge
    /// here (where navPath lives) so nav-pop + delete happen in one atomic transaction.
    var purgeTrigger: Bool = false
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onSelectPin: ((PinnedLocationData) -> Void)? = nil
    var onZoomToPin: ((PinnedLocationData) -> Void)? = nil
    var onClearPin: (() -> Void)? = nil
    var onRevealPins: (([PinnedLocationData]) -> Void)? = nil
    var onOpenCarousel: ((PinnedLocationData) -> Void)? = nil
    /// Opens a script in the Script view (third island mode).
    var onOpenScript: ((ScriptData) -> Void)? = nil
    /// Opens a script scene (highlight) in the Script view, scrolled to its range.
    var onOpenScriptHighlight: ((ScriptHighlight) -> Void)? = nil
    /// Context-menu reveal handlers (route to ContentView): show the pin in the grid / on the map.
    var onRevealInGrid: ((UUID) -> Void)? = nil
    var onRevealOnMap: ((UUID) -> Void)? = nil
    /// Set by photo grid to scroll the sidebar to the tapped pin.
    var scrollToPinUUID: UUID? = nil
    /// Set by "Reveal in List" (grid/map) to expand the pin's list/folder chain and scroll to it.
    var revealInListUUID: UUID? = nil
    /// Set when a script highlight is clicked — reveal & select that LIST (centered) in the sidebar.
    var revealListUUID: UUID? = nil
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
    @State private var expandedProjectTrash = false
    @State private var showEmptyProjectTrashConfirm = false

    var body: some View {
        NavigationStack(path: $navPath) {
            projectList
                .navigationDestination(for: ProjectData.self) { project in
                    ProjectDetailView(
                        project: project,
                        selection: selection,
                        initialExpandedUUIDs: storedExpandedUUIDs,
                        activeListIDs: $activeListIDs,
                        hiddenUncategorizedProjectIDs: $hiddenUncategorizedProjectIDs,
                        onFitToList: onFitToList,
                        onSelectPin: onSelectPin,
                        onZoomToPin: onZoomToPin,
                        onClearPin: onClearPin,
                        onRevealPins: onRevealPins,
                        onOpenCarousel: onOpenCarousel,
                        onOpenScript: onOpenScript,
                        onOpenScriptHighlight: onOpenScriptHighlight,
                        onRevealInGrid: onRevealInGrid,
                        onRevealOnMap: onRevealOnMap,
                        onExpandedChanged: { uuids in
                            expandedListUUIDs = uuids.joined(separator: ",")
                        },
                        scrollToPinUUID: scrollToPinUUID,
                        revealInListUUID: revealInListUUID,
                        revealListUUID: revealListUUID,
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
            purgeExpiredProjects()
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
                        // Soft-delete: move to Trash (auto-purged after 30 days).
                        if navPath.first?.persistentModelID == project.persistentModelID {
                            navPath = []
                            openProjectUUID = ""
                            expandedListUUIDs = ""
                        }
                        project.deletedAt = Date()
                        try? modelContext.save()
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                }
            }
            // Trash section — trashed projects, collapsible, with Empty Trash + 30-day auto-purge.
            if !trashedProjects.isEmpty {
                projectTrashSection
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
        .confirmationDialog("Permanently delete \(trashedProjects.count) project\(trashedProjects.count == 1 ? "" : "s") and all their contents?",
                            isPresented: $showEmptyProjectTrashConfirm, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { emptyProjectTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. All lists, photos, and scripts inside the trashed projects will be permanently deleted.")
        }
    }

    // MARK: - Project Trash

    private var projectTrashSection: some View {
        Section {
            // Header row: chevron + icon + "Trash" label + day count + Empty Trash button.
            HStack(spacing: 6) {
                Button {
                    var tx = Transaction(); tx.disablesAnimations = false
                    withTransaction(tx) { expandedProjectTrash.toggle() }
                } label: {
                    Image(systemName: expandedProjectTrash ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
                Text("Trash").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text("(\(trashedProjects.count))").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) { showEmptyProjectTrashConfirm = true } label: {
                    Text("Empty").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red.opacity(0.8))
            }
            .listRowBackground(Color.clear)
            .padding(.top, 4)

            if expandedProjectTrash {
                ForEach(trashedProjects) { project in
                    trashedProjectRow(project)
                }
            }
        }
    }

    private func trashedProjectRow(_ project: ProjectData) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name.isEmpty ? "(untitled)" : project.name)
                    .font(.subheadline).lineLimit(1).foregroundStyle(.secondary)
                if let deletedAt = project.deletedAt {
                    let daysLeft = max(0, 30 - Int(Date().timeIntervalSince(deletedAt) / 86400))
                    Text("\(daysLeft) day\(daysLeft == 1 ? "" : "s") left")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                project.deletedAt = nil
                try? modelContext.save()
            } label: {
                Text("Put Back").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Button(role: .destructive) {
                purgeProject(project)
            } label: {
                Text("Delete").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
        }
        .listRowBackground(Color.red.opacity(0.06))
    }

    /// Permanently deletes a trashed project and all its contents. Must pop nav first if open.
    private func purgeProject(_ project: ProjectData) {
        if navPath.first?.persistentModelID == project.persistentModelID {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { navPath = [] }
            openProjectUUID = ""
            expandedListUUIDs = ""
            activeListIDs = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                hardDeleteProject(project)
            }
        } else {
            hardDeleteProject(project)
        }
    }

    private func hardDeleteProject(_ project: ProjectData) {
        // Manually detach children before deleting to prevent cascade failures that leave
        // orphaned records (SwiftData cascade isn't always honored with CloudKit store).
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
    }

    /// Permanently deletes all trashed projects and their contents.
    private func emptyProjectTrash() {
        // Pop nav first if we're inside a trashed project.
        if let open = navPath.first, open.deletedAt != nil {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { navPath = [] }
            openProjectUUID = ""
            expandedListUUIDs = ""
            activeListIDs = []
        }
        for project in trashedProjects { hardDeleteProject(project) }
    }

    /// Auto-purges projects that have been in the Trash for more than 30 days.
    private func purgeExpiredProjects() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for project in trashedProjects where (project.deletedAt ?? .distantFuture) < cutoff {
            purgeProject(project)
        }
    }
}

// MARK: - Sidebar selection model

/// Holds the sidebar's multi-selection as a reference type. The parent owns this via
/// plain `@State` (NOT `@StateObject`), so mutating the set does NOT re-render the parent
/// or rebuild the row list. Only the rows themselves observe it via `@ObservedObject`, and
/// because the List is lazy, only the handful of on-screen rows ever repaint — selecting
/// thousands of off-screen rows is an O(1) set assignment with no visual work.
// MARK: - Sidebar item (unified photo + list)

private enum SidebarItem: Identifiable {
    case photo(PinnedLocationData)
    case list(LocationListData)
    /// The virtual "Uncategorized" row — a reorderable, collapsible top-level pseudo-list
    /// that holds every loose photo (no list). Identified by its owning project.
    case uncategorized(ProjectData)

    var id: PersistentIdentifier {
        switch self {
        case .photo(let p): return p.persistentModelID
        case .list(let l): return l.persistentModelID
        case .uncategorized(let proj): return proj.persistentModelID
        }
    }

    var panelOrder: Int {
        switch self {
        case .photo(let p): return p.panelOrder
        case .list(let l): return l.panelOrder
        case .uncategorized(let proj): return proj.uncategorizedPanelOrder
        }
    }

    var createdAt: Date {
        switch self {
        case .photo(let p): return p.createdAt
        case .list(let l): return l.createdAt
        case .uncategorized: return .distantPast
        }
    }

    var dragID: String {
        switch self {
        case .photo(let p): return "photo:\(p.uuid.uuidString)"
        case .list(let l): return "list:\(l.uuid.uuidString)"
        case .uncategorized: return "uncategorized"
        }
    }

    /// Drag kind for SidebarDragState — photos suppress between-lists insertion lines.
    var dragKind: SidebarDragKind {
        if case .photo = self { return .photo }
        return .list   // lists and the uncategorized pseudo-list reorder among top-level rows
    }
}

// MARK: - Drag-to-reorder / nest

/// Which zone of a row the drag cursor is over: reorder before/after the row, or nest the
/// dragged item into it (lists only).
private enum DropMode { case before, into, after }

/// Drop delegate that maps the cursor's vertical position within a row to a drop zone. Rows
/// that accept nesting (lists) carve out a center "into" band; all rows have before/after
/// edge bands for reordering. Reports the live zone for preview and performs the drop.
private struct SidebarRowDropDelegate: DropDelegate {
    let targetID: PersistentIdentifier
    let allowNest: Bool
    let height: () -> CGFloat
    let onTargetChange: (PersistentIdentifier?, DropMode) -> Void
    /// Clear the highlight only if this row still owns it — avoids a race where the old row's
    /// dropExited fires after the new row's dropEntered and wipes the fresh target.
    let onExit: (PersistentIdentifier) -> Void
    let onPerform: (DropMode, [NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) { onTargetChange(targetID, mode(info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let m = mode(info)
        onTargetChange(targetID, m)
        // `.copy` shows the green "+" badge on the cursor (signals "nest into"); `.move`
        // shows no badge (plain reorder between rows).
        return DropProposal(operation: m == .into ? .copy : .move)
    }

    func dropExited(info: DropInfo) { onExit(targetID) }

    func performDrop(info: DropInfo) -> Bool {
        let m = mode(info)
        onTargetChange(nil, .before)
        return onPerform(m, info.itemProviders(for: [.text, .fileURL, .image]))
    }

    private func mode(_ info: DropInfo) -> DropMode {
        let h = max(height(), 1)
        let y = info.location.y
        if allowNest {
            // A PHOTO dragged onto a list can only be dropped INTO it — there's no meaningful
            // "between lists" position for a photo — so highlight the whole row and never show a
            // before/after insertion line. LIST drags keep the before/into/after zones so lists
            // can still be reordered. (allowNest:false rows — pin rows — are unaffected: photos
            // ARE reorderable among other photos there.)
            #if os(macOS)
            if SidebarDragState.shared.kind == .photo { return .into }
            #endif
            if y < h * 0.30 { return .before }
            if y > h * 0.70 { return .after }
            return .into
        }
        return y < h * 0.5 ? .before : .after
    }
}

// MARK: - Project detail (unified reorderable list)

private struct ProjectDetailView: View {
    @Bindable var project: ProjectData
    /// THE shared selection store (sidebar + grid + map). Held as a plain `var` (NOT
    /// @ObservedObject) so mutating it never re-runs THIS view's body / its ForEach — only the
    /// PinRow/ListRow leaves observe it and repaint. Observing it here would rebuild the whole
    /// list on every click (the documented sidebar-selection perf footgun).
    var selection: SelectionStore
    var initialExpandedUUIDs: Set<String> = []
    @Binding var activeListIDs: Set<PersistentIdentifier>
    @Binding var hiddenUncategorizedProjectIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onSelectPin: ((PinnedLocationData) -> Void)?
    var onZoomToPin: ((PinnedLocationData) -> Void)?
    var onClearPin: (() -> Void)?
    var onRevealPins: (([PinnedLocationData]) -> Void)? = nil
    var onOpenCarousel: ((PinnedLocationData) -> Void)? = nil
    var onOpenScript: ((ScriptData) -> Void)? = nil
    var onOpenScriptHighlight: ((ScriptHighlight) -> Void)? = nil
    /// Context-menu reveal handlers (route to ContentView).
    var onRevealInGrid: ((UUID) -> Void)? = nil
    var onRevealOnMap: ((UUID) -> Void)? = nil
    var onExpandedChanged: (([String]) -> Void)? = nil
    /// Set from the photo grid to scroll the sidebar to a specific pin.
    var scrollToPinUUID: UUID? = nil
    /// Set by "Reveal in List" — expand this pin's list/folder chain and scroll to its row.
    var revealInListUUID: UUID? = nil
    /// Set when a script highlight is clicked — expand & scroll to that LIST's row (centered).
    var revealListUUID: UUID? = nil
    /// Set by ContentView (from M key or grid context menu) to open the move sheet
    /// for specific location UUIDs, bypassing sidebar selection.
    @Binding var externalMoveUUIDs: [UUID]

    @Environment(\.modelContext) private var modelContext
    @State private var showAddList = false
    @State private var newListName = ""
    @State private var expandedListIDs: Set<PersistentIdentifier> = []
    // Whether the Uncategorized pseudo-list is expanded to show its loose photos.
    @State private var uncategorizedExpanded = false
    // Whether the "Scripts" pseudo-list is expanded to show imported scripts.
    @State private var scriptsExpanded = false
    @State private var renamingList: LocationListData? = nil
    @State private var renameListText = ""
    @State private var isBackfilling = false
    @State private var showMovePopup = false
    /// The list whose scene-type popover is open (anchored to its row), or nil. Set by pressing "e".
    @State private var sceneTypeEditID: UUID? = nil
    @State private var searchText = ""
    @State private var importProgress: (current: Int, total: Int)? = nil
    @State private var timelineProgress: (current: Int, total: Int, name: String)? = nil
    // Selection lives in a reference-type model owned via plain @State (NOT @StateObject),
    // so mutating it never re-renders this view or re-runs ForEach(sidebarItems). Only the
    // handful of on-screen rows observe it via @ObservedObject, so selecting (or shift-
    // selecting thousands of) rows repaints only what's visible — instant regardless of count.
    // Cached sidebar items — rebuilt only when photos/lists actually change,
    // not on every render triggered by selection or scroll state.
    @State private var cachedSidebarItems: [SidebarItem] = []
    // Held so moveSelection can scroll without needing to be inside the ScrollViewReader body.
    @State private var listProxyHolder: ScrollViewProxy? = nil
    // Undo stack of trashed-photo batches (each batch = the persistent ids trashed together).
    // ⌘Z pops the last batch and restores those photos.
    @State private var trashUndoStack: [[PersistentIdentifier]] = []
    @State private var expandedTrash = false
    // Lists awaiting a delete confirmation, plus any photos selected alongside them. A list is
    // never deleted without this confirm step; on confirm it (and its photos) go to the Trash.
    @State private var listsPendingDelete: [LocationListData] = []
    @State private var pinsPendingDelete: [PinnedLocationData] = []
    @State private var showDeleteListConfirm = false
    // Top-level row currently under a reorder drag — a blue insertion line is drawn at its
    // top edge to preview where the dragged item will land (it inserts before this row).
    @State private var dropTargetID: PersistentIdentifier? = nil
    // Whether the current drag will reorder (line before/after the row) or nest into a list
    // (the whole row highlights). Decided from the cursor's vertical position within the row.
    @State private var dropMode: DropMode = .before
    // Watchdog that clears the drop indicator shortly after drag activity stops — covers drags
    // that end outside any row (or are cancelled), where SwiftUI doesn't fire dropExited and the
    // mouse-up that ends a drag session isn't seen by the event monitor. Each drop update resets
    // it; AppKit fires periodic drag updates while a drag is live, so it only triggers once the
    // drag has actually ended.
    @State private var dropClearWork: DispatchWorkItem? = nil
    // Measured heights per row so the drop delegate can map cursor-Y to a drop zone.
    @State private var rowHeights: [PersistentIdentifier: CGFloat] = [:]
    // macOS mouse-event monitor that clears a stuck drop indicator. SwiftUI's DropDelegate
    // sometimes fails to deliver dropExited when a drag is cancelled, leaving the blue
    // insertion line on screen; releasing the mouse (or the next click) clears it here.
    #if os(macOS)
    @State private var dragEndMonitor: Any? = nil
    #endif
    // True only while the user has clicked into the sidebar search field. Bare-letter
    // keys (e.g. the "m" Move shortcut) must not be swallowed by the field unless it's
    // actually focused, so we resign this whenever a row is selected.
    @FocusState private var searchFieldFocused: Bool

    /// One flat, ordered entry per visible row. Carries both the `uuid` (the selection key,
    /// shared with the grid and map) and the `scrollID` (the row's ScrollViewReader identity,
    /// which is its PersistentIdentifier). Used for shift-range selection and arrow-key nav.
    private struct FlatRow { let uuid: UUID; let scrollID: PersistentIdentifier }
    private var flatVisibleRows: [FlatRow] {
        var result: [FlatRow] = []
        for item in cachedSidebarItems {
            switch item {
            case .photo(let pin):
                result.append(FlatRow(uuid: pin.uuid, scrollID: pin.persistentModelID))
            case .list(let list):
                result.append(FlatRow(uuid: list.uuid, scrollID: list.persistentModelID))
                if expandedListIDs.contains(list.persistentModelID) {
                    for p in flaggedFirst(list.pins.filter { $0.deletedAt == nil }) {
                        result.append(FlatRow(uuid: p.uuid, scrollID: p.persistentModelID))
                    }
                }
            case .uncategorized(let proj):
                result.append(FlatRow(uuid: proj.uuid, scrollID: proj.persistentModelID))
                if uncategorizedExpanded {
                    for p in loosePhotos {
                        result.append(FlatRow(uuid: p.uuid, scrollID: p.persistentModelID))
                    }
                }
            }
        }
        return result
    }

    /// Single click selects just this row (and fires the map side effect).
    /// Shift-click extends a contiguous range from the anchor.
    /// Option-click toggles this item in/out of a disparate selection.
    private func handleTap(_ id: UUID, shift: Bool, option: Bool = false) {
        // Selecting a row takes keyboard focus off the search field so bare-letter
        // shortcuts (like "m" to Move) aren't typed into the search box.
        searchFieldFocused = false
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
            let order = flatVisibleRows.map(\.uuid)
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                selection.ids = Set(order[min(a, b)...max(a, b)])
            } else {
                selection.ids = [id]; selection.anchor = id
            }
            return   // range select: no map nav
        }
        selection.ids = [id]
        selection.anchor = id
        if let pin = findPin(uuid: id) {
            if pin.hasGPS { onSelectPin?(pin) } else { onClearPin?() }
        } else if let list = findList(uuid: id) {
            // Only navigate the map for a list that's actually visible on it. Clicking a hidden
            // (eye-off) list just selects it and leaves the map untouched.
            if activeListIDs.contains(list.persistentModelID) {
                onClearPin?()
                onFitToList?(list.pins.filter { $0.hasGPS })
            }
        }
    }

    /// Double-click zooms into a pin (or fits to a list). No-GPS pins open in carousel.
    private func handleDoubleTap(_ id: UUID) {
        if let pin = findPin(uuid: id) {
            if pin.hasGPS {
                onZoomToPin?(pin)
            } else {
                onOpenCarousel?(pin)
            }
        } else if let list = findList(uuid: id) {
            // Double-click toggles the list's visibility (eye on/off).
            if activeListIDs.contains(list.persistentModelID) {
                // Toggling OFF — just hide this one.
                activeListIDs.remove(list.persistentModelID)
            } else {
                // Toggling ON — "solo" this list. Hide every OTHER top-level list/folder,
                // keeping only this list's own top-level ancestor. Other folders are flipped
                // at the top-level gate; their nested children keep their own eye state.
                var topAncestor = list
                while let parent = topAncestor.parentList { topAncestor = parent }
                for top in project.lists where top.parentList == nil {
                    if top.persistentModelID == topAncestor.persistentModelID {
                        activeListIDs.insert(top.persistentModelID)
                    } else {
                        activeListIDs.remove(top.persistentModelID)
                    }
                }
                // If this list lives inside a folder, also hide its sibling lists so only
                // this one shows within the folder; its folder is made visible below.
                if let folder = list.parentList {
                    for sibling in folder.childLists where sibling.persistentModelID != list.persistentModelID {
                        activeListIDs.remove(sibling.persistentModelID)
                    }
                }
                // Ensure the clicked list and its whole ancestor chain (folder) are active so
                // the folder visibility gate lets it show through.
                var node: LocationListData? = list
                while let n = node {
                    activeListIDs.insert(n.persistentModelID)
                    node = n.parentList
                }
                // Uncategorized is a top-level list too — hide it when soloing a real list.
                hiddenUncategorizedProjectIDs.insert(project.persistentModelID)
            }
        }
    }

    /// Double-click on the Uncategorized row: toggle its visibility, soloing it (hide every
    /// top-level list) when turning on — exactly how double-clicking a normal list behaves.
    private func handleUncategorizedDoubleTap() {
        if uncategorizedVisible {
            hiddenUncategorizedProjectIDs.insert(project.persistentModelID)
        } else {
            for top in project.lists where top.parentList == nil {
                activeListIDs.remove(top.persistentModelID)
            }
            hiddenUncategorizedProjectIDs.remove(project.persistentModelID)
        }
    }

    /// Whether this project's uncategorized (loose) photos are shown on map + grid.
    private var uncategorizedVisible: Bool {
        !hiddenUncategorizedProjectIDs.contains(project.persistentModelID)
    }

    /// Toggles every list AND the uncategorized photos in this project on/off at once.
    /// Used by Option-clicking any eye.
    private func setProjectVisibility(_ visible: Bool) {
        let pid = project.persistentModelID
        if visible {
            project.lists.forEach { activeListIDs.insert($0.persistentModelID) }
            hiddenUncategorizedProjectIDs.remove(pid)
        } else {
            project.lists.forEach { activeListIDs.remove($0.persistentModelID) }
            hiddenUncategorizedProjectIDs.insert(pid)
        }
    }

    /// Moves keyboard selection up (-1) or down (+1) through the flat visible row list.
    /// If the next item is a list, it auto-expands it and steps inside to its first pin.
    private func moveSelection(_ delta: Int) {
        let flat = flatVisibleRows
        guard !flat.isEmpty else { return }
        let current = selection.anchor ?? flat.first!.uuid
        guard let idx = flat.firstIndex(where: { $0.uuid == current }) else { return }
        var next = max(0, min(flat.count - 1, idx + delta))

        // If the target is a collapsed list and we're moving into it, expand it first
        // and step to its first pin (or last pin when moving up).
        let targetUUID = flat[next].uuid
        if let list = cachedSidebarItems.compactMap({ item -> LocationListData? in
                if case .list(let l) = item { return l } else { return nil }
            }).first(where: { $0.uuid == targetUUID }),
           !expandedListIDs.contains(list.persistentModelID) {
            let pins = flaggedFirst(list.pins.filter { $0.deletedAt == nil })
            if !pins.isEmpty {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) { expandedListIDs.insert(list.persistentModelID) }
                // Re-compute flat after expansion to find the pin's index.
                let newFlat = flatVisibleRows
                let targetPin = delta > 0 ? pins.first! : pins.last!
                if let pinIdx = newFlat.firstIndex(where: { $0.uuid == targetPin.uuid }) {
                    next = pinIdx
                }
            }
        }

        let newFlat = flatVisibleRows
        guard next < newFlat.count else { return }
        let target = newFlat[next]
        selection.ids = [target.uuid]
        selection.anchor = target.uuid

        // Fire the same map / photo-mode side effects as a tap.
        if let pin = findPin(uuid: target.uuid) {
            onSelectPin?(pin)
        }

        // .none anchor: only scrolls enough to make the row visible; doesn't re-center.
        // Scroll by the row's ScrollViewReader identity (PersistentIdentifier), not the uuid.
        listProxyHolder?.scrollTo(target.scrollID, anchor: .none)
    }

    private func rebuildSidebarItems() {
        // Top-level rows are the lists/folders plus the virtual "Uncategorized" row, which
        // holds every loose photo and is itself a reorderable top-level item. Loose photos
        // are NOT individual top-level rows anymore — they render nested under Uncategorized.
        var items = project.lists
            .filter { $0.parentList == nil && $0.deletedAt == nil }
            .map { SidebarItem.list($0) }
        if !loosePhotos.isEmpty {
            items.append(.uncategorized(project))
        }
        cachedSidebarItems = items.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    /// This project's live (non-trashed) loose photos — the contents of Uncategorized.
    private var loosePhotos: [PinnedLocationData] {
        project.importedPhotos
            .filter { $0.deletedAt == nil }
            .sorted { $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt }
    }

    // Use cachedSidebarItems everywhere the old sidebarItems was used.
    private var sidebarItems: [SidebarItem] { cachedSidebarItems }

    // MARK: - Folder nesting

    private func nestList(_ list: LocationListData, into folder: LocationListData) {
        list.parentList?.childLists.removeAll { $0.persistentModelID == list.persistentModelID }
        list.parentList = folder
        if !folder.childLists.contains(where: { $0.persistentModelID == list.persistentModelID }) {
            folder.childLists.append(list)
        }
        try? modelContext.save()
        rebuildSidebarItems()
    }

    private func unnestList(_ list: LocationListData) {
        list.parentList?.childLists.removeAll { $0.persistentModelID == list.persistentModelID }
        list.parentList = nil
        try? modelContext.save()
        rebuildSidebarItems()
    }

    /// Drop handler for child-list rows inside a folder. Handles BOTH:
    ///  • photo(s)/pin dropped INTO the child list (mode `.into`) → move them into it, and
    ///  • a sibling child list reordered before/after (mode `.before`/`.after`).
    /// External files/images are imported into the child list when dropped onto it.
    private func performChildRowDrop(_ providers: [NSItemProvider], folder: LocationListData,
                                      target child: LocationListData, mode: DropMode) -> Bool {
        // External files/images → import directly into this nested list.
        if mode == .into, tryImportDrop(providers, into: child) { return true }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                // Photos/pins dropped INTO the nested list → move them in.
                if mode == .into {
                    if dragID.hasPrefix("photos:") {
                        let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                        movePins(uuids.compactMap { findPin(uuid: $0) }, intoList: child)
                        return
                    }
                    if dragID.hasPrefix("photo:") || dragID.hasPrefix("pin:") {
                        let uuid = dragID.hasPrefix("pin:") ? String(dragID.dropFirst(4)) : String(dragID.dropFirst(6))
                        if let pin = findPin(uuid: uuid) { movePinsToList(pin, intoList: child) }
                        return
                    }
                }
                // A sibling child list dragged → reorder within the folder.
                if dragID.hasPrefix("list:") {
                    let uuid = String(dragID.dropFirst(5))
                    guard let dragged = folder.childLists.first(where: { $0.uuid.uuidString == uuid }) else { return }
                    reorderChild(dragged, in: folder, before: child, after: mode == .after)
                }
            }
        }
        return true
    }

    /// Reorders a child list within its folder — same pattern as `reorder(_:before:after:)`
    /// but scoped to the folder's `childLists` array.
    private func reorderChild(_ dragged: LocationListData, in folder: LocationListData,
                               before target: LocationListData, after: Bool) {
        var children = folder.childLists.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
        guard let from = children.firstIndex(where: { $0.persistentModelID == dragged.persistentModelID }),
              dragged.persistentModelID != target.persistentModelID else { return }
        let moving = children.remove(at: from)
        guard let to = children.firstIndex(where: { $0.persistentModelID == target.persistentModelID }) else { return }
        children.insert(moving, at: after ? to + 1 : to)
        for (i, child) in children.enumerated() { child.panelOrder = i }
        try? modelContext.save()
    }


    /// Assigns sequential panelOrder values. Debounced so rapid imports (200 photos)
    /// don't fire 200 consecutive full-list writes.
    private func normalizeOrder() {
        // Rebuild the display list first so it's current.
        rebuildSidebarItems()
        // Normalize panelOrder values — only write when stale to avoid cascading updates.
        for (i, item) in cachedSidebarItems.enumerated() {
            switch item {
            case .photo(let p):            if p.panelOrder != i { p.panelOrder = i }
            case .list(let l):             if l.panelOrder != i { l.panelOrder = i }
            case .uncategorized(let proj): if proj.uncategorizedPanelOrder != i { proj.uncategorizedPanelOrder = i }
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

    /// UUID overload — pins are selected by their stable `uuid` (the shared selection key).
    private func findPin(uuid: UUID) -> PinnedLocationData? {
        if let p = project.importedPhotos.first(where: { $0.uuid == uuid }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.uuid == uuid }) { return p }
        }
        return nil
    }

    /// Lists currently selected in the sidebar (the shared selection holds list uuids too),
    /// excluding trashed lists. Drives the "e" scene-type shortcut.
    private var selectedLists: [LocationListData] {
        selection.ids.compactMap { findList(uuid: $0) }.filter { $0.deletedAt == nil }
    }

    /// Finds a list/folder anywhere in the project by its `uuid`.
    private func findList(uuid: UUID) -> LocationListData? {
        project.lists.first(where: { $0.uuid == uuid })
    }

    /// "Reveal in List": expand the pin's whole list/folder ancestor chain (so its row exists),
    /// select/highlight it, and scroll the sidebar to it.
    /// Scrolls the sidebar list to a row, retrying since freshly-expanded rows are lazy.
    private func scrollSidebar(to target: PersistentIdentifier, using proxy: ScrollViewProxy) {
        for delay in [0.1, 0.35, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// Expands ONLY the revealed pin's list/folder chain (collapsing every other list), selects
    /// it, and returns its scroll id (the caller scrolls to it via the ScrollViewReader proxy).
    @discardableResult
    private func revealPin(_ uuid: UUID) -> PersistentIdentifier? {
        guard let pin = findPin(uuid: uuid) else { return nil }
        // A sidebar search filter can hide the pin's row entirely — clear it so the row exists.
        if !searchText.isEmpty { searchText = "" }
        var tx = Transaction(animation: .none); tx.disablesAnimations = true
        withTransaction(tx) {
            if let list = pin.list {
                // Collapse everything else; expand ONLY this pin's list + ancestor folders.
                var chain = Set<PersistentIdentifier>()
                var node: LocationListData? = list
                while let n = node { chain.insert(n.persistentModelID); node = n.parentList }
                expandedListIDs = chain
                uncategorizedExpanded = false
            } else {
                // Loose photo → collapse lists, expand only Uncategorized.
                expandedListIDs = []
                uncategorizedExpanded = true
            }
        }
        // Highlight it in every view.
        selection.ids = [pin.uuid]
        selection.anchor = pin.uuid
        return pin.persistentModelID
    }

    /// Expands a list's ancestor folder chain (so its row exists), selects it, and returns its
    /// scroll id — for revealing a list when its script highlight is clicked.
    @discardableResult
    private func revealList(_ uuid: UUID) -> PersistentIdentifier? {
        guard let list = findList(uuid: uuid) else { return nil }
        if !searchText.isEmpty { searchText = "" }
        var tx = Transaction(animation: .none); tx.disablesAnimations = true
        withTransaction(tx) {
            var chain = Set<PersistentIdentifier>()
            var node: LocationListData? = list.parentList
            while let n = node { chain.insert(n.persistentModelID); node = n.parentList }
            expandedListIDs = chain
            uncategorizedExpanded = false
        }
        selection.ids = [list.uuid]
        selection.anchor = list.uuid
        return list.persistentModelID
    }

    /// Flagged ("favorite filming location") pins first — keeping each group's sortOrder — so
    /// flagging a pin floats it to the top of its list, like pinning a chat.
    private func flaggedFirst(_ pins: [PinnedLocationData]) -> [PinnedLocationData] {
        pins.sorted { a, b in
            a.isFlagged == b.isFlagged ? a.sortOrder < b.sortOrder : a.isFlagged
        }
    }

    /// Toggles the flagged state of `primary` (plus any other selected pins). If any are
    /// unflagged, flags them all; otherwise unflags them all.
    private func toggleFlag(_ primary: PinnedLocationData) {
        var pins = [primary]
        if selection.contains(primary.uuid) {
            for id in selection.ids where id != primary.uuid {
                if let p = findPin(uuid: id) { pins.append(p) }
            }
        }
        let shouldFlag = pins.contains { !$0.isFlagged }
        for p in pins { p.isFlagged = shouldFlag }
        try? modelContext.save()
    }

    // Drag-start helpers. Each records the drag kind (so list rows can suppress the between-
    // lists insertion line for photo drags) and returns the payload provider. Kept as small
    // functions so the (already large) sidebar view body stays type-checkable.
    private func beginItemDrag(_ item: SidebarItem) -> NSItemProvider {
        SidebarDragState.shared.kind = item.dragKind
        return NSItemProvider(object: item.dragID as NSString)
    }
    private func beginPhotoDrag(_ payload: String) -> NSItemProvider {
        SidebarDragState.shared.kind = .photo
        return NSItemProvider(object: payload as NSString)
    }
    private func beginListDrag(_ payload: String) -> NSItemProvider {
        SidebarDragState.shared.kind = .list
        return NSItemProvider(object: payload as NSString)
    }

    /// Drop onto a pin row INSIDE a list: reorder there (before/after the row) or import files.
    /// `beforeNeighbor` is the pin immediately above `target` (nil if `target` is first), used to
    /// place the dropped photo correctly for a `.before` drop.
    private func reorderPinDrop(_ providers: [NSItemProvider], list: LocationListData,
                                target: PinnedLocationData, beforeNeighbor: PinnedLocationData?,
                                mode: DropMode) -> Bool {
        if tryImportDrop(providers, into: list) { return true }
        let after: PinnedLocationData? = (mode == .after) ? target : beforeNeighbor
        return loadDropPin(providers, intoList: list, afterPin: after)
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
                // Grid photo drag(s) onto a list header: move the pin(s) into the list.
                // Handles both single "photo:<uuid>" and multi "photos:<uuid>,..." payloads,
                // resolving pins directly (they may live inside another list, so they aren't
                // top-level sidebar items that handleDrop's resolve() could find).
                if case .list(let list) = target,
                   dragID.hasPrefix("photo:") || dragID.hasPrefix("photos:") {
                    if dragID.hasPrefix("photos:") {
                        // Grid multi-drag: move exactly the pins named in the payload.
                        let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                        movePins(uuids.compactMap { findPin(uuid: $0) }, intoList: list)
                    } else {
                        // Single "photo:" (grid single or sidebar loose photo) keeps the
                        // sidebar-selection-expanding path.
                        if let pin = findPin(uuid: String(dragID.dropFirst(6))) {
                            movePinsToList(pin, intoList: list)
                        }
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
                if selection.contains(primaryPin.uuid) {
                    for id in selection.ids where id != primaryPin.uuid {
                        if let p = findPin(uuid: id), p.list != nil { pinsToMove.append(p) }
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

    /// Core move: relocates EXACTLY `pins` into `list`, with no selection expansion.
    /// Use this for grid drags — their payload ("photos:a,b,c") already names every dragged
    /// photo. Routing those through `movePinsToList` instead re-expanded each pin via the
    /// SIDEBAR selection (a different selection from the grid's), pulling in unrelated pins —
    /// that was the "shift-select 3, list count jumps by 5–6" drag bug.
    private func movePins(_ pins: [PinnedLocationData], intoList list: LocationListData, afterPin: PinnedLocationData? = nil) {
        // Only pins not already in the target list. De-dupe by identity so a payload that
        // accidentally repeats an id can't move (or count) the same pin twice.
        var seen = Set<PersistentIdentifier>()
        // De-dupe only. Do NOT skip pins already in `list`: a drop onto a row in the SAME list
        // is a reorder, and the sortOrder logic below repositions them correctly (detach +
        // re-add). Skipping same-list pins made reordering within a list a silent no-op.
        let moving = pins.filter { seen.insert($0.persistentModelID).inserted }
        guard !moving.isEmpty else { return }
        for pin in moving {
            detach(pin)
            // Setting the inverse relationship is enough — SwiftData adds the pin to
            // list.pins automatically. Do NOT also insert into list.pins, or the pin ends
            // up in the array twice (caused a "Duplicate values for key" crash on the map).
            pin.list = list
        }
        // Compute the final order purely via sortOrder. Existing members (excluding the just-
        // moved ones) keep their order; the moved pins go after `afterPin`, else to the front.
        let movingIDs = Set(moving.map(\.persistentModelID))
        var ordered = list.pins
            .filter { !movingIDs.contains($0.persistentModelID) }
            .sorted { $0.sortOrder < $1.sortOrder }
        if let after = afterPin, moving.count == 1,
           let idx = ordered.firstIndex(where: { $0.persistentModelID == after.persistentModelID }) {
            ordered.insert(contentsOf: moving, at: idx + 1)
        } else {
            ordered.insert(contentsOf: moving, at: 0)
        }
        for (i, p) in ordered.enumerated() { p.sortOrder = i }
        normalizeOrder()
        try? modelContext.save()
    }

    /// Sidebar single-pin/row drag: moves `primaryPin` PLUS any other pins selected in the
    /// SIDEBAR into `list`. Only for sidebar drags ("pin:"/"photo:" rows), where one dragged
    /// row should carry the whole sidebar selection. Grid drags must use `movePins` instead.
    private func movePinsToList(_ primaryPin: PinnedLocationData, intoList list: LocationListData, afterPin: PinnedLocationData? = nil) {
        var pins: [PinnedLocationData] = [primaryPin]
        if selection.contains(primaryPin.uuid) {
            for id in selection.ids where id != primaryPin.uuid {
                if let pin = findPin(uuid: id) { pins.append(pin) }
            }
        }
        movePins(pins, intoList: list, afterPin: afterPin)
    }

    /// Moves a pin (and any other selected pins) out of its list into Uncategorized (loose).
    private func moveSelectedPinsToUncategorized(primary: PinnedLocationData) {
        var pins: [PinnedLocationData] = [primary]
        if selection.contains(primary.uuid) {
            for id in selection.ids where id != primary.uuid {
                if let p = findPin(uuid: id) { pins.append(p) }
            }
        }
        for pin in pins { movePinToUncategorized(pin) }
    }

    /// Detaches a single pin from wherever it lives and makes it a loose (Uncategorized) photo.
    private func movePinToUncategorized(_ pin: PinnedLocationData) {
        guard pin.list != nil else { return }   // already loose
        detach(pin)
        pin.owningProject = project
        pin.panelOrder = (loosePhotos.map(\.panelOrder).max() ?? -1) + 1
        project.importedPhotos.append(pin)
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
                    // Grid multi-drag: move exactly the listed pins, no selection expansion.
                    let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                    movePins(uuids.compactMap { findPin(uuid: $0) }, intoList: list, afterPin: afterPin)
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
    private func handleDrop(_ dragID: String, onto target: SidebarItem, after: Bool = false) -> Bool {
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
            case .uncategorized:
                // Dropping a list pin onto Uncategorized removes it from its list.
                moveSelectedPinsToUncategorized(primary: pin)
            }
            return true
        }

        // A nested list dragged onto a top-level row → unnest it to the top level, ordered
        // next to the target. (resolve() only finds top-level items, so handle lists first.)
        if dragID.hasPrefix("list:") {
            let uuid = String(dragID.dropFirst(5))
            if let list = project.lists.first(where: { $0.uuid.uuidString == uuid }),
               list.parentList != nil {
                list.parentList?.childLists.removeAll { $0.persistentModelID == list.persistentModelID }
                list.parentList = nil
                reorderToTopLevel(list, near: target, after: after)
                return true
            }
        }

        // Top-level item dragged onto another top-level item.
        guard let dragged = resolve(dragID) else { return false }
        if dragged.id == target.id { return false }

        // Top-level photo dragged onto a list → move into list (with multi-select support).
        if case .photo(let pin) = dragged, case .list(let list) = target, !after {
            movePinsToList(pin, intoList: list)
            return true
        }

        // Otherwise reorder.
        reorder(dragged, before: target, after: after)
        return true
    }

    /// Re-inserts a now-top-level model (e.g. a just-unnested list) next to `target`.
    private func reorderToTopLevel(_ list: LocationListData, near target: SidebarItem, after: Bool) {
        rebuildSidebarItems()
        reorder(.list(list), before: target, after: after)
    }

    /// Reorders `dragged` next to `target`. Inserts before the target row (or after it when
    /// `after` is true), so every slot — including just below the last row — is reachable.
    private func reorder(_ dragged: SidebarItem, before target: SidebarItem, after: Bool = false) {
        var items = sidebarItems
        guard let from = items.firstIndex(where: { $0.id == dragged.id }) else { return }
        let moving = items.remove(at: from)
        guard let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.insert(moving, at: after ? to + 1 : to)
        for (i, item) in items.enumerated() {
            switch item {
            case .photo(let p):            p.panelOrder = i
            case .list(let l):             l.panelOrder = i
            case .uncategorized(let proj): proj.uncategorizedPanelOrder = i
            }
        }
        try? modelContext.save()
        // Rebuild the cached sidebar items so the new panelOrder is reflected on screen —
        // writing panelOrder alone doesn't re-sort the @State-cached display array.
        rebuildSidebarItems()
    }

    /// Soft-deletes a photo by moving it to the Trash (keeps its list/project membership so
    /// it can be restored in place). Pushes an undo batch so ⌘Z brings it back.
    private func deletePin(_ pin: PinnedLocationData) {
        trashPins([pin])
    }

    /// Moves photos to the Trash and records an undo batch. Lists are never trashed —
    /// they're not photos — so this only touches pins.
    private func trashPins(_ pins: [PinnedLocationData]) {
        let live = pins.filter { $0.deletedAt == nil }
        guard !live.isEmpty else { return }
        let now = Date()
        for pin in live {
            pin.deletedAt = now
            selection.ids.remove(pin.uuid)
        }
        trashUndoStack.append(live.map { $0.persistentModelID })
        normalizeOrder()
        try? modelContext.save()
    }

    /// Deletes every currently-selected sidebar item. Photos go straight to the Trash
    /// (undoable). Lists are NEVER deleted without an explicit confirmation — if the selection
    /// includes any list, we stash everything and show a confirm dialog first.
    private func deleteSelectedItems() {
        let ids = selection.ids
        guard !ids.isEmpty else { return }
        var pins: [PinnedLocationData] = []
        var lists: [LocationListData] = []
        for id in ids {
            if let pin = findPin(uuid: id) {
                pins.append(pin)
            } else if let list = findList(uuid: id) {
                lists.append(list)
            }
        }
        if lists.isEmpty {
            // Photos only — trash immediately (undoable, no confirm needed).
            selection.ids = []
            trashPins(pins)
        } else {
            // Any list selected → confirm before trashing.
            listsPendingDelete = lists
            pinsPendingDelete = pins
            showDeleteListConfirm = true
        }
    }

    /// Requests deletion of a single list (from its row's context menu) — always confirms.
    private func requestDeleteList(_ list: LocationListData) {
        listsPendingDelete = [list]
        pinsPendingDelete = []
        showDeleteListConfirm = true
    }

    /// Carries out a confirmed delete: lists (and any co-selected photos) move to the Trash.
    private func confirmDeletePending() {
        for list in listsPendingDelete { trashList(list) }
        let pins = pinsPendingDelete
        listsPendingDelete = []
        pinsPendingDelete = []
        selection.ids = []
        if !pins.isEmpty { trashPins(pins) } else { normalizeOrder(); try? modelContext.save() }
    }

    /// Human-readable summary for the delete-confirmation dialog.
    private var deleteConfirmMessage: String {
        let listCount = listsPendingDelete.count
        // Count photos that will go to the trash with the lists (their pins + descendants).
        let listPhotoCount = listsPendingDelete.reduce(0) { $0 + photoCount(in: $1) }
        let extraPhotos = pinsPendingDelete.count
        let listWord = listCount == 1 ? "list" : "lists"
        var parts = ["\(listCount) \(listWord)"]
        let totalPhotos = listPhotoCount + extraPhotos
        if totalPhotos > 0 { parts.append("\(totalPhotos) photo\(totalPhotos == 1 ? "" : "s")") }
        return "Move \(parts.joined(separator: " and ")) to the Trash? Items are removed permanently after 30 days."
    }

    /// Live (non-trashed) photo count in a list, including its descendant child lists.
    private func photoCount(in list: LocationListData) -> Int {
        list.pins.filter { $0.deletedAt == nil }.count
            + list.childLists.reduce(0) { $0 + photoCount(in: $1) }
    }

    /// Soft-deletes a list (and, for folders, its child lists) to the Trash. The list's photos
    /// travel with it implicitly — they stay attached, hidden because their list is trashed.
    private func trashList(_ list: LocationListData) {
        let now = Date()
        func mark(_ l: LocationListData) {
            if l.deletedAt == nil { l.deletedAt = now }
            activeListIDs.remove(l.persistentModelID)
            selection.ids.remove(l.uuid)
            for child in l.childLists { mark(child) }
        }
        mark(list)
        normalizeOrder()
        try? modelContext.save()
    }

    /// Restores a trashed list (and its trashed child lists) from the Trash.
    private func restoreList(_ list: LocationListData) {
        func clear(_ l: LocationListData) {
            l.deletedAt = nil
            for child in l.childLists where child.deletedAt != nil { clear(child) }
        }
        clear(list)
        normalizeOrder()
        try? modelContext.save()
    }

    /// Permanently deletes a trashed list and everything under it (pins + child lists cascade).
    private func purgeList(_ list: LocationListData) {
        list.project = nil
        list.parentList = nil
        modelContext.delete(list)   // cascade removes pins and child lists
        try? modelContext.save()
    }

    // MARK: - Trash

    /// All trashed photos in this project (top-level, or individually trashed inside a LIVE
    /// list). Photos inside a trashed *list* are excluded — they travel with their list and
    /// show under it in the Trash, not as loose photos.
    private var trashedPins: [PinnedLocationData] {
        var pins = project.importedPhotos.filter { $0.deletedAt != nil }
        for list in project.lists where list.deletedAt == nil {
            pins += list.pins.filter { $0.deletedAt != nil }
        }
        return pins.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Trashed lists shown in the Trash — only the root of each trashed subtree (a trashed
    /// child whose parent is also trashed is hidden under its parent), newest first.
    private var trashedLists: [LocationListData] {
        project.lists
            .filter { $0.deletedAt != nil && ($0.parentList == nil || $0.parentList?.deletedAt == nil) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Restores a trashed photo back to wherever it lived.
    private func restoreFromTrash(_ pin: PinnedLocationData) {
        pin.deletedAt = nil
        normalizeOrder()
        try? modelContext.save()
    }

    /// ⌘Z — restores the most recent batch of trashed photos. Falls back to the single
    /// newest trashed photo so deletes made elsewhere (e.g. the carousel) are also undoable.
    private func undoLastTrash() {
        if let batch = trashUndoStack.popLast() {
            for id in batch {
                if let pin = findPin(byID: id) { pin.deletedAt = nil }
            }
        } else if let latest = trashedPins.first {   // trashedPins is sorted newest-first
            latest.deletedAt = nil
        } else {
            return
        }
        normalizeOrder()
        try? modelContext.save()
    }

    /// Permanently deletes a single trashed photo (right-click → Delete Permanently).
    private func purgePin(_ pin: PinnedLocationData) {
        if let list = pin.list {
            list.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
        } else {
            project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
        }
        modelContext.delete(pin)
        try? modelContext.save()
    }

    /// Empties the Trash — permanently deletes every trashed photo AND trashed list.
    private func emptyTrash() {
        for pin in trashedPins { purgePin(pin) }
        for list in trashedLists { purgeList(list) }
        try? modelContext.save()
    }

    /// Purges photos and lists that have been in the Trash longer than 30 days. Called on appear.
    private func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for pin in trashedPins.filter({ ($0.deletedAt ?? .distantFuture) < cutoff }) { purgePin(pin) }
        for list in trashedLists.filter({ ($0.deletedAt ?? .distantFuture) < cutoff }) { purgeList(list) }
        try? modelContext.save()
    }

    /// True when `id` is part of a multi-item selection (used to switch context-menu
    /// actions and labels between single-item and whole-selection delete).
    private func isInMultiSelection(_ id: UUID) -> Bool {
        selection.ids.count > 1 && selection.ids.contains(id)
    }

    /// "Delete Photos (3)" when the selection is all photos/pins, else "Delete Items (3)".
    private var deleteSelectionLabel: String {
        let allPhotos = selection.ids.allSatisfy { findPin(uuid: $0) != nil }
        return allPhotos ? "Delete Photos (\(selection.ids.count))"
                         : "Delete Items (\(selection.ids.count))"
    }


    /// Trimmed search query; empty means no filtering.
    private var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }
    private func nameMatches(_ s: String) -> Bool {
        trimmedSearch.isEmpty || s.localizedCaseInsensitiveContains(trimmedSearch)
    }
    /// Sidebar items filtered by the search query (matches photo names; keeps lists that
    /// match by name or contain a matching photo).
    private var displayedItems: [SidebarItem] {
        guard !trimmedSearch.isEmpty else { return sidebarItems }
        return sidebarItems.compactMap { item in
            switch item {
            case .photo(let p):
                return nameMatches(p.name) ? item : nil
            case .list(let list):
                if nameMatches(list.name) { return item }
                if list.pins.contains(where: { nameMatches($0.name) }) { return item }
                // Also match if any child list name or its pins match.
                let childMatch = list.childLists.contains {
                    nameMatches($0.name) || $0.pins.contains { nameMatches($0.name) }
                }
                return childMatch ? item : nil
            case .uncategorized:
                // Keep Uncategorized visible while searching if any loose photo matches.
                return loosePhotos.contains { nameMatches($0.name) } ? item : nil
            }
        }
    }

    private var sidebarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search photos…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFieldFocused)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, sidebarTopPadding)
        .padding(.bottom, 6)
    }

    /// Drag-to-reorder/nest overlay for one row. Shows a blue insertion line at the top
    /// edge (mode `.before`), bottom edge (mode `.after`), or a full-row highlight when the
    /// drag will nest the dragged list into this list (mode `.into`).
    @ViewBuilder
    private func dropIndicator(for id: PersistentIdentifier) -> some View {
        if dropTargetID == id {
            switch dropMode {
            case .before:
                VStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 4)
                    Spacer(minLength: 0)
                }
            case .after:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 4)
                }
            case .into:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 1.5)
                    )
                    .padding(.horizontal, 2)
            }
        }
    }

    /// Transparent background view that measures and records a row's height, so the drop
    /// delegate can map the cursor's vertical position to a before/into/after zone.
    private func rowHeightReader(_ id: PersistentIdentifier) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { rowHeights[id] = geo.size.height }
                .onChange(of: geo.size.height) { _, h in rowHeights[id] = h }
        }
    }

    /// Records the row currently under the drag and which zone (before/into/after) the cursor
    /// is in, so `dropIndicator` can preview the result.
    private func setDropTarget(_ id: PersistentIdentifier?, mode: DropMode) {
        if dropTargetID != id { dropTargetID = id }
        if dropMode != mode { dropMode = mode }
        // Re-arm the watchdog on every drag update; it fires only after updates stop (drag ended).
        dropClearWork?.cancel()
        guard id != nil else { return }
        let work = DispatchWorkItem { dropTargetID = nil; dropMode = .before }
        dropClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Clears the drag highlight only if `id` is still the active target (see onExit docs).
    private func clearDropTarget(ifOwnedBy id: PersistentIdentifier) {
        if dropTargetID == id { dropTargetID = nil }
    }

    /// Performs a row drop based on the resolved zone. `.into` a list nests a dragged list or
    /// moves a dragged photo into it; `.before`/`.after` reorder at the top level.
    private func performRowDrop(target: SidebarItem, mode: DropMode, providers: [NSItemProvider]) -> Bool {
        // External files/images: import into the list when dropped onto it, else top-level.
        let importList: LocationListData? = {
            if case .list(let l) = target { return l }
            return nil
        }()
        if tryImportDrop(providers, into: mode == .into ? importList : nil) { return true }

        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                self.dispatchRowDrop(dragID: dragID, target: target, mode: mode)
            }
        }
        return true
    }

    @MainActor
    private func dispatchRowDrop(dragID: String, target: SidebarItem, mode: DropMode) {
        // Drop photos/pins onto the Uncategorized row → remove them from their list (loose).
        if case .uncategorized = target,
           dragID.hasPrefix("photo:") || dragID.hasPrefix("photos:") || dragID.hasPrefix("pin:") {
            let uuids: [String]
            if dragID.hasPrefix("photos:") { uuids = dragID.dropFirst(7).split(separator: ",").map(String.init) }
            else if dragID.hasPrefix("photo:") { uuids = [String(dragID.dropFirst(6))] }
            else { uuids = [String(dragID.dropFirst(4))] }
            for pin in uuids.compactMap({ findPin(uuid: $0) }) { movePinToUncategorized(pin) }
            return
        }
        // Nest-into a list.
        if mode == .into, case .list(let folder) = target {
            // Dragged list → nest as a child folder.
            if dragID.hasPrefix("list:") {
                let uuid = String(dragID.dropFirst(5))
                guard let dragged = project.lists.first(where: { $0.uuid.uuidString == uuid }),
                      dragged.persistentModelID != folder.persistentModelID else { return }
                // Prevent nesting a folder into its own descendant.
                guard !isDescendant(folder, of: dragged) else { return }
                nestList(dragged, into: folder)
                return
            }
            // Dragged photo(s) → move into the list.
            if dragID.hasPrefix("photos:") {
                // Grid multi-drag: move exactly the listed pins, no selection expansion.
                let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                movePins(uuids.compactMap { findPin(uuid: $0) }, intoList: folder)
                return
            }
            if dragID.hasPrefix("photo:") || dragID.hasPrefix("pin:") {
                // Single sidebar row: carry the sidebar selection.
                let uuid = dragID.hasPrefix("photo:") ? String(dragID.dropFirst(6)) : String(dragID.dropFirst(4))
                if let pin = findPin(uuid: uuid) { movePinsToList(pin, intoList: folder) }
                return
            }
            return
        }
        // Reorder before/after the target at the top level.
        _ = handleDrop(dragID, onto: target, after: mode == .after)
    }

    /// True if `candidate` is `ancestor` or a descendant of `ancestor` (guards nesting cycles).
    private func isDescendant(_ candidate: LocationListData, of ancestor: LocationListData) -> Bool {
        var node: LocationListData? = candidate
        while let n = node {
            if n.persistentModelID == ancestor.persistentModelID { return true }
            node = n.parentList
        }
        return false
    }

    /// Auto "Scripts" section (like Uncategorized/Trash): imported .fountain scripts.
    @ViewBuilder
    private var scriptsSection: some View {
        let scripts = project.scripts.sorted { $0.sortOrder < $1.sortOrder }
        if !scripts.isEmpty {
            HStack(spacing: 6) {
                Button {
                    var tx = Transaction(animation: .none); tx.disablesAnimations = true
                    withTransaction(tx) { scriptsExpanded.toggle() }
                } label: {
                    Image(systemName: scriptsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                Text("Scripts").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(scripts.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .listRowBackground(Color.clear)

            if scriptsExpanded {
                ForEach(scripts, id: \.persistentModelID) { script in
                    scriptRow(script)
                }
            }
        }
    }

    @ViewBuilder
    private func scriptRow(_ script: ScriptData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.plaintext").font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(script.name).font(.body).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
        .onTapGesture { onOpenScript?(script) }
        .contextMenu {
            Button { onOpenScript?(script) } label: { Label("Open Script", systemImage: "doc.text") }
            Divider()
            Button(role: .destructive) { deleteScript(script) } label: {
                Label("Delete Script", systemImage: "trash")
            }
        }
    }

    private func deleteScript(_ script: ScriptData) {
        modelContext.delete(script)
        try? modelContext.save()
    }

    /// Trash section — soft-deleted lists and photos, with Empty Trash. Auto-purged at 30 days.
    @ViewBuilder
    private var trashSection: some View {
        let trashed = trashedPins
        let trashedListRows = trashedLists
        if !trashed.isEmpty || !trashedListRows.isEmpty {
            HStack(spacing: 6) {
                Button {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) { expandedTrash.toggle() }
            } label: {
                    Image(systemName: expandedTrash ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
                Text("Trash").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(trashed.count + trashedListRows.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button(role: .destructive) { emptyTrash() } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
            }
            .help("Items here are deleted automatically after 30 days")

            if expandedTrash {
                ForEach(trashedListRows, id: \.persistentModelID) { list in
                    trashedListRow(list)
                }
                ForEach(trashed, id: \.persistentModelID) { pin in
                    trashedPinRow(pin)
                }
            }
        }
    }

    /// A single trashed-photo row in the Trash section.
    @ViewBuilder
    private func trashedPinRow(_ pin: PinnedLocationData) -> some View {
        PinRow(pin: pin, selection: selection, onTap: { _, _ in }, onDoubleTap: {})
            .padding(.leading, 24)
            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
            .opacity(0.6)
            .contextMenu {
                Button { restoreFromTrash(pin) } label: {
                    Label("Put Back", systemImage: "arrow.uturn.backward")
                }
                Divider()
                Button(role: .destructive) { purgePin(pin) } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
            }
    }

    /// A single trashed-list row in the Trash section, with Put Back / Delete Permanently.
    @ViewBuilder
    private func trashedListRow(_ list: LocationListData) -> some View {
        let n = photoCount(in: list)
        HStack(spacing: 6) {
            Image(systemName: list.childLists.isEmpty ? "list.bullet" : "folder")
                .font(.caption).foregroundStyle(.secondary).frame(width: 14)
            Text(list.name).font(.body).foregroundStyle(.primary)
            Spacer()
            if n > 0 { Text("\(n)").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .opacity(0.6)
        .contextMenu {
            Button { restoreList(list) } label: {
                Label("Put Back", systemImage: "arrow.uturn.backward")
            }
            Divider()
            Button(role: .destructive) { purgeList(list) } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }
    }

    /// The Uncategorized pseudo-list row + its loose photos. Behaves like a normal list:
    /// collapsible, reorderable among top-level rows, eye toggle. It can't be nested into a
    /// folder, always holds the project's loose photos, and is the default import target.
    @ViewBuilder
    private func uncategorizedSection(_ proj: ProjectData, itemID: PersistentIdentifier) -> some View {
        let searching = !trimmedSearch.isEmpty
        let isExpanded = searching || uncategorizedExpanded
        let photos = searching ? loosePhotos.filter { nameMatches($0.name) } : loosePhotos

        HStack(spacing: 6) {
            Button {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) { uncategorizedExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Drag handle: only this region starts a reorder drag (matches ListRow).
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                Text("Uncategorized").font(.body).foregroundStyle(.primary)
                Spacer()
                if !loosePhotos.isEmpty {
                    Text("\(loosePhotos.count)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onDrag { beginListDrag("uncategorized") }

            Button {
                let pid = proj.persistentModelID
                if currentModifierFlags().option {
                    setProjectVisibility(!uncategorizedVisible)
                } else if uncategorizedVisible {
                    hiddenUncategorizedProjectIDs.insert(pid)
                } else {
                    hiddenUncategorizedProjectIDs.remove(pid)
                }
            } label: {
                Image(systemName: uncategorizedVisible ? "eye.fill" : "eye")
                    .foregroundStyle(uncategorizedVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show/hide uncategorized photos on the map and grid (⌥ toggles everything)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            searchFieldFocused = false
            onClearPin?()
            onFitToList?(loosePhotos.filter { $0.hasGPS })
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { handleUncategorizedDoubleTap() })
        .background { rowHeightReader(itemID) }
        .overlay { dropIndicator(for: itemID) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: itemID,
                    allowNest: false,
                    height: { rowHeights[itemID] ?? 36 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in performRowDrop(target: .uncategorized(proj), mode: mode, providers: providers) }
                ))

        if isExpanded {
            ForEach(photos) { pin in
                PinRow(
                    pin: pin,
                    selection: selection,
                    onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
                    onDoubleTap: { handleDoubleTap(pin.uuid) }
                )
                .padding(.leading, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
                .contextMenu { pinContextMenu(pin) }
                .onDrag { beginPhotoDrag("photo:\(pin.uuid.uuidString)") }
                .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                    tryImportDrop(providers, into: nil) || loadDropPinToUncategorized(providers)
                }
            }
        }
    }

    /// Loads a drag payload and moves the dragged pin(s) into Uncategorized (loose photos).
    private func loadDropPinToUncategorized(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                let uuids: [String]
                if dragID.hasPrefix("photos:") { uuids = dragID.dropFirst(7).split(separator: ",").map(String.init) }
                else if dragID.hasPrefix("photo:") { uuids = [String(dragID.dropFirst(6))] }
                else if dragID.hasPrefix("pin:") { uuids = [String(dragID.dropFirst(4))] }
                else { return }
                for pin in uuids.compactMap({ findPin(uuid: $0) }) { movePinToUncategorized(pin) }
            }
        }
        return true
    }

    /// One top-level sidebar row (extracted from the List ForEach to keep the body
    /// type-checkable). Dispatches to the loose-photo, list, or uncategorized row.
    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        switch item {
        case .photo(let pin):       topPhotoRow(pin, item: item)
        case .list(let list):       listSection(list, item: item)
        case .uncategorized(let p): uncategorizedSection(p, itemID: item.id)
        }
    }

    /// A loose (top-level) photo row.
    @ViewBuilder
    private func topPhotoRow(_ pin: PinnedLocationData, item: SidebarItem) -> some View {
        PinRow(
            pin: pin,
            selection: selection,
            onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(pin.uuid) }
        )
        .contextMenu { pinContextMenu(pin) }
        .background { rowHeightReader(item.id) }
        .overlay { dropIndicator(for: item.id) }
        .onDrag { beginItemDrag(item) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: item.id,
                    allowNest: false,
                    height: { rowHeights[item.id] ?? 60 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in performRowDrop(target: .photo(pin), mode: mode, providers: providers) }
                ))
    }

    /// A list/folder header row, plus its expanded child lists and pins.
    @ViewBuilder
    private func listSection(_ list: LocationListData, item: SidebarItem) -> some View {
        // While searching, force lists open so matching photos are visible.
        let searching = !trimmedSearch.isEmpty
        let isExpanded = searching || expandedListIDs.contains(list.persistentModelID)
        let isFolder = !list.childLists.isEmpty
        let isNested = list.parentList != nil
        ListRow(
            list: list,
            isExpanded: isExpanded,
            isFolder: isFolder,
            isNested: isNested,
            selection: selection,
            onToggleExpand: {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) {
                    if isExpanded { expandedListIDs.remove(list.persistentModelID) }
                    else { expandedListIDs.insert(list.persistentModelID) }
                }
            },
            onTap: { shift, option in handleTap(list.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(list.uuid) },
            activeListIDs: $activeListIDs,
            onFitToList: onFitToList,
            onRename: {
                renameListText = list.name
                renamingList = list
            },
            onToggleAllVisibility: { makeAllActive in
                setProjectVisibility(makeAllActive)
            },
            onMoveToTopLevel: { unnestList(list) },
            onDelete: { requestDeleteList(list) },
            dragProvider: { beginItemDrag(item) },
            sceneTypeEditID: $sceneTypeEditID,
            onOpenSceneLink: { onOpenScriptHighlight?($0) }
        )
        .background { rowHeightReader(item.id) }
        .overlay { dropIndicator(for: item.id) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: item.id,
                    allowNest: true,
                    height: { rowHeights[item.id] ?? 36 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in performRowDrop(target: .list(list), mode: mode, providers: providers) }
                ))

        if isExpanded {
            // Script scenes assigned to this list — pinned at the TOP of the list (above photos
            // and child lists). Click to jump to that spot in the script.
            let scenes = list.sceneLinks.sorted { $0.rangeStart < $1.rangeStart }
            ForEach(scenes, id: \.persistentModelID) { scene in
                sceneRow(scene, color: Color(hexString: list.colorHex))
            }

            // Child lists (folders) shown before pins.
            let childLists = list.childLists
                .filter { $0.deletedAt == nil }
                .sorted {
                    $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
                }.filter { !searching || nameMatches($0.name) || $0.pins.contains { nameMatches($0.name) } }
            ForEach(childLists, id: \.persistentModelID) { child in
                childListRow(child, folder: list)
            }

            let pins = flaggedFirst(list.pins.filter { $0.deletedAt == nil })
                .filter { !searching || nameMatches(list.name) || nameMatches($0.name) }
            ForEach(Array(pins.enumerated()), id: \.element.persistentModelID) { idx, pin in
                expandedPinRow(pin, in: list, indexBefore: idx > 0 ? pins[idx - 1] : nil)
            }
        }
    }

    /// A "scene" row inside an expanded list: the linked script excerpt; tap to open it.
    @ViewBuilder
    private func sceneRow(_ scene: ScriptHighlight, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").font(.caption2).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if let h = scene.sceneHeading, !h.isEmpty {
                    Text(h).font(.caption.weight(.medium)).lineLimit(1)
                }
                Text(scene.excerpt.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
        .onTapGesture { onOpenScriptHighlight?(scene) }
        .contextMenu {
            Button { onOpenScriptHighlight?(scene) } label: { Label("Open in Script", systemImage: "doc.text") }
            Divider()
            Button(role: .destructive) { deleteSceneLink(scene) } label: {
                Label("Remove Scene Link", systemImage: "trash")
            }
        }
    }

    private func deleteSceneLink(_ scene: ScriptHighlight) {
        modelContext.delete(scene)
        try? modelContext.save()
    }

    /// A pin row shown inside an expanded list, with reorder drop support.
    @ViewBuilder
    private func expandedPinRow(_ pin: PinnedLocationData, in list: LocationListData,
                                indexBefore beforeNeighbor: PinnedLocationData?) -> some View {
        PinRow(
            pin: pin,
            selection: selection,
            listColor: Color(hexString: list.colorHex),
            onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(pin.uuid) }
        )
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .contextMenu { pinContextMenu(pin) }
        .background { rowHeightReader(pin.persistentModelID) }
        .overlay { dropIndicator(for: pin.persistentModelID) }
        .onDrag { beginPhotoDrag("pin:\(pin.uuid.uuidString)") }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: pin.persistentModelID,
                    allowNest: false,
                    height: { rowHeights[pin.persistentModelID] ?? 60 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in
                        reorderPinDrop(providers, list: list, target: pin,
                                       beforeNeighbor: beforeNeighbor, mode: mode)
                    }
                ))
    }

    /// One child-list row inside a folder, with drag-to-reorder and its pin expansion.
    @ViewBuilder
    private func childListRow(_ child: LocationListData, folder: LocationListData) -> some View {
        let childExpanded = expandedListIDs.contains(child.persistentModelID)
        ListRow(
            list: child,
            isExpanded: childExpanded,
            isFolder: false,
            isNested: true,
            selection: selection,
            onToggleExpand: {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) {
                    if childExpanded { expandedListIDs.remove(child.persistentModelID) }
                    else { expandedListIDs.insert(child.persistentModelID) }
                }
            },
            onTap: { shift, option in handleTap(child.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(child.uuid) },
            activeListIDs: $activeListIDs,
            onFitToList: onFitToList,
            onRename: {
                renameListText = child.name
                renamingList = child
            },
            onMoveToTopLevel: { unnestList(child) },
            onDelete: { requestDeleteList(child) },
            dragProvider: { beginListDrag("list:\(child.uuid.uuidString)") },
            sceneTypeEditID: $sceneTypeEditID,
            onOpenSceneLink: { onOpenScriptHighlight?($0) }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 0))
        .padding(.leading, 18)
        // NOTE: deliberately NO rowHeightReader/GeometryReader here. A GeometryReader's
        // onAppear writes the `rowHeights` @State on every child mount, and each write
        // re-renders this whole view — so a folder with N children fired N extra body
        // passes on expand, making folders far slower to open than plain photo lists.
        // These rows are single-line and use allowNest:false (a plain before/after split
        // at the midpoint), so a constant height is exact enough for drag-reorder.
        .overlay { dropIndicator(for: child.persistentModelID) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: child.persistentModelID,
                    // Allow nesting so the middle zone is a "drop INTO this list" target (the
                    // row highlights) — needed so photos can be dropped straight into a list
                    // that lives inside a folder, not just reordered around it.
                    allowNest: true,
                    height: { 36 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in
                        performChildRowDrop(providers, folder: folder, target: child, mode: mode)
                    }
                ))

        if childExpanded {
            // Scene links pinned at the top of the child list too.
            let scenes = child.sceneLinks.sorted { $0.rangeStart < $1.rangeStart }
            ForEach(scenes, id: \.persistentModelID) { scene in
                sceneRow(scene, color: Color(hexString: child.colorHex))
                    .padding(.leading, 18)
            }

            let childPins = flaggedFirst(child.pins.filter { $0.deletedAt == nil })
            ForEach(childPins) { pin in
                PinRow(
                    pin: pin,
                    selection: selection,
                    listColor: Color(hexString: child.colorHex),
                    onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
                    onDoubleTap: { handleDoubleTap(pin.uuid) }
                )
                .padding(.leading, 42)
                .listRowInsets(EdgeInsets(top: 0, leading: 42, bottom: 0, trailing: 0))
                .contextMenu { pinContextMenu(pin) }
            }
        }
    }

    /// Right-click menu for a sidebar pin row — uses the SHARED pin menu (origin .sidebar), so
    /// it's identical to the grid/map menus aside from the sidebar-only "Reveal in Photo Grid"
    /// and "Reveal on Map" options.
    @ViewBuilder private func pinContextMenu(_ pin: PinnedLocationData) -> some View {
        pinContextMenuItems(.sidebar, sidebarPinMenuActions(pin))
    }

    private func sidebarPinMenuActions(_ pin: PinnedLocationData) -> PinMenuActions {
        let multi = isInMultiSelection(pin.uuid)
        var revealFinder: (() -> Void)? = nil
        #if os(macOS)
        if let path = pin.originalFilePath {
            revealFinder = { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        }
        #endif
        return PinMenuActions(
            isFlagged: pin.isFlagged,
            toggleFlag: { toggleFlag(pin) },
            revealInFinder: revealFinder,
            revealInList: nil,
            revealInGrid: onRevealInGrid.map { f in { f(pin.uuid) } },
            revealOnMap: onRevealOnMap.map { f in { f(pin.uuid) } },
            delete: { if multi { deleteSelectedItems() } else { deletePin(pin) } }
        )
    }

    var body: some View {
        ScrollViewReader { listProxy in
        let _ = { listProxyHolder = listProxy }()
        VStack(spacing: 0) {
        sidebarSearchField
        List {
            // Scripts are pinned to the very top and are not part of the reorderable items, so
            // nothing can be dragged above them.
            scriptsSection

            ForEach(displayedItems) { item in
                sidebarRow(item)
            }

            trashSection

            // Bottom drop zone — same as the top one, for when the list is scrolled down.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .listRowBackground(Color.clear)
                .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                    tryImportDrop(providers, into: nil) || loadDropToTopLevel(providers, atTop: false)
                }
        }
        // Reserve a constant right-hand gutter for the scrollbar so row width never
        // changes when the scroller appears/disappears on long lists. (macOS-only AppKit.)
        #if os(macOS)
        .background(ScrollerGutterReserver(width: 14))
        #endif
        .onAppear {
            normalizeOrder()
            purgeExpiredTrash()   // remove photos trashed > 30 days ago
            // project.lists is synchronously available here via SwiftData.
            if !initialExpandedUUIDs.isEmpty {
                expandedListIDs = Set(
                    project.lists.filter { initialExpandedUUIDs.contains($0.uuid.uuidString) }
                                 .map(\.persistentModelID)
                )
            }
            #if os(macOS)
            // Clear any stuck drop indicator on mouse-up / next click (see dragEndMonitor docs).
            if dragEndMonitor == nil {
                dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDown]) { event in
                    if dropTargetID != nil { dropTargetID = nil }
                    return event
                }
            }
            #endif
        }
        #if os(macOS)
        .onDisappear {
            if let m = dragEndMonitor { NSEvent.removeMonitor(m); dragEndMonitor = nil }
        }
        #endif
        // Delete key removes the current selection. A hidden keyboard-shortcut button is
        // used instead of `.onDeleteCommand` because the latter makes the List a focus
        // sink on macOS, which blocks click-to-focus on TextFields elsewhere in the window
        // (e.g. the Google Maps search box). The actions no-op on an empty selection, and a
        // focused TextField consumes the key itself, so these never interfere with typing.
        .background {
            // Disabled while renaming so the rename field gets every keystroke — otherwise
            // backspace deletes the list, Shift+A (a capital "A") clears the selection, etc.
            Group {
                Button("", action: deleteSelectedItems)
                    .keyboardShortcut(.delete, modifiers: [])
                Button("") { selection.ids = []; selection.anchor = nil }
                    .keyboardShortcut("a", modifiers: .shift)
                // ⌘Z restores the most recently trashed batch of photos.
                Button("", action: undoLastTrash)
                    .keyboardShortcut("z", modifiers: .command)
            }
            .disabled(renamingList != nil)
            .opacity(0)
            .allowsHitTesting(false)
        }
        .onChange(of: project.importedPhotos.count) { normalizeOrder() }
        .onChange(of: project.lists.count) { normalizeOrder() }
        // Rebuild when photos are trashed/restored elsewhere (e.g. the carousel's delete)
        // — soft-delete doesn't change the relationship counts above, so this watches the
        // trashed count to keep the sidebar and Trash section in sync.
        .onChange(of: trashedPins.count) { normalizeOrder() }
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
                    Button { importScript() } label: {
                        Label("Import Script…", systemImage: "doc.text")
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
        // A sheet (not .alert) so the field reliably shows the existing name pre-filled — a
        // TextField inside a macOS .alert doesn't reflect a pre-set binding value.
        .sheet(item: $renamingList) { list in
            NameEntrySheet(
                title: "Rename List",
                placeholder: "List name",
                text: $renameListText,
                confirmLabel: "Rename",
                onDismiss: { renamingList = nil }
            ) { name in
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    list.name = trimmed
                    try? modelContext.save()
                }
                renamingList = nil
            }
        }
        .confirmationDialog(
            "Delete List",
            isPresented: $showDeleteListConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { confirmDeletePending() }
            Button("Cancel", role: .cancel) {
                listsPendingDelete = []
                pinsPendingDelete = []
            }
        } message: {
            Text(deleteConfirmMessage)
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
                  let pin = findPin(uuid: uuid) else { return }
            // Scroll the sidebar to this pin's row. Do NOT touch `selection` here: selection is
            // now the shared store driven by actual selection actions (grid/map/sidebar clicks),
            // and the sidebar rows already reflect it. Overwriting it with [pin.uuid] on every
            // highlight change clobbered grid/map MULTI-select back to a single item — that was
            // the long-standing "can't multi-select in the grid" bug.
            listProxyHolder?.scrollTo(pin.persistentModelID, anchor: nil)
        }
        .onChange(of: revealInListUUID) { _, uuid in
            guard let uuid, let target = revealPin(uuid) else { return }
            scrollSidebar(to: target, using: listProxy)
        }
        .onChange(of: revealListUUID) { _, uuid in
            guard let uuid, let target = revealList(uuid) else { return }
            scrollSidebar(to: target, using: listProxy)
        }
        } // VStack
        } // ScrollViewReader
        // All sidebar key handlers are suppressed while the rename popup is open so its text field
        // gets every keystroke — only its own Return (onSubmit) commits the name.
        .onKeyPress(.downArrow) { renamingList != nil ? .ignored : { moveSelection(1); return .handled }() }
        .onKeyPress(.upArrow)   { renamingList != nil ? .ignored : { moveSelection(-1); return .handled }() }
        // "e" with a list selected: open the scene-type chooser as a popover anchored to the row.
        // Lives here (not as a global keyboardShortcut) so a focused text field consumes "e"
        // normally — only fires when the sidebar itself has keyboard focus.
        .onKeyPress(KeyEquivalent("e")) {
            guard renamingList == nil, let target = selectedLists.first else { return .ignored }
            sceneTypeEditID = target.uuid
            return .handled
        }
        // Enter with a list selected: rename it (reuses the row's rename flow).
        .onKeyPress(.return) {
            guard renamingList == nil, let target = selectedLists.first else { return .ignored }
            renameListText = target.name
            renamingList = target
            return .handled
        }
        // Hidden M key button — opens Move popup when sidebar pins are selected.
        .background {
            Button("") {
                let hasPins = selection.ids.contains(where: { findPin(uuid: $0) != nil })
                if hasPins { showMovePopup = true }
            }
            .keyboardShortcut("m", modifiers: [])
            // Disable while the move popup or rename popup is open so typing into their fields
            // can't re-fire this shortcut.
            .disabled(showMovePopup || renamingList != nil)
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
                return selection.ids.compactMap { findPin(uuid: $0)?.uuid }
            }()
            MoveToListSheet(
                project: project,
                onMove: { list in
                    let pins = moveIDs.compactMap { uuid in
                        project.lists.flatMap(\.pins).first(where: { $0.uuid == uuid })
                        ?? project.importedPhotos.first(where: { $0.uuid == uuid })
                    }
                    pins.forEach { movePinsToList($0, intoList: list) }
                    selection.ids = []
                    selection.anchor = nil
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
        #if os(macOS)
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
        #endif
        // iOS uses PhotosPicker instead — see IOS_PLAN.md (not wired into this Mac sidebar).
    }

    /// Imports one or more `.fountain` scripts: reads each file's text into a new ScriptData
    /// (copied in, not referenced) under the project's "Scripts" section.
    private func importScript() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Import Script"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "fountain") ?? .plainText, .plainText, .text]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return }
        var nextOrder = (project.scripts.map(\.sortOrder).max() ?? -1) + 1
        for url in panel.urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let script = ScriptData(name: name, rawText: text, sortOrder: nextOrder)
            nextOrder += 1
            modelContext.insert(script)
            script.project = project
        }
        try? modelContext.save()
        scriptsExpanded = true
        #endif
    }

    /// Picks a Google Maps Timeline JSON export and backfills GPS onto photos that lack it
    /// by matching their EXIF capture time to the timeline's locations.
    private func pickTimelineAndBackfill() {
        #if os(macOS)
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
        #endif
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
    var isFolder: Bool = false
    var isNested: Bool = false
    @ObservedObject var selection: SelectionStore
    let onToggleExpand: () -> Void
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onRename: (() -> Void)? = nil
    /// Called when the user Option+clicks the eye. `true` = show all, `false` = hide all.
    var onToggleAllVisibility: ((Bool) -> Void)? = nil
    var onMoveToTopLevel: (() -> Void)? = nil
    /// Called when the user chooses "Delete List". The parent shows a confirm dialog and
    /// moves the list to the Trash — ListRow never deletes directly.
    var onDelete: (() -> Void)? = nil
    /// Supply a drag provider to make the name area a drag handle. Buttons are
    /// excluded so accidental drag on chevron/eye never triggers a reorder.
    var dragProvider: (() -> NSItemProvider)? = nil
    /// Which list's scene-type popover is open (shared across rows); the popover anchors to the
    /// row whose `list.uuid` matches. Set by clicking the chip or the panel's "e" shortcut.
    var sceneTypeEditID: Binding<UUID?>? = nil
    /// Tapping the header's scene-count badge opens the script at that scene link.
    var onOpenSceneLink: ((ScriptHighlight) -> Void)? = nil
    @Environment(\.modelContext) private var modelContext

    private var isActive: Bool { activeListIDs.contains(list.persistentModelID) }
    private var isSelected: Bool { selection.contains(list.uuid) }
    private var listColor: Color { Color(hexString: list.colorHex) }

    /// Live (non-trashed) photo count for a list, including its live child lists (recursively).
    static func liveCount(_ list: LocationListData) -> Int {
        list.pins.filter { $0.deletedAt == nil }.count
            + list.childLists.filter { $0.deletedAt == nil }.reduce(0) { $0 + liveCount($1) }
    }

    /// True if any live photo in this list (or a live child list) is flagged — so the header can
    /// show a flag, signalling a filming location has already been chosen for the list.
    static func hasFlagged(_ list: LocationListData) -> Bool {
        list.pins.contains { $0.deletedAt == nil && $0.isFlagged }
            || list.childLists.filter { $0.deletedAt == nil }.contains { hasFlagged($0) }
    }

    /// Scene-type chip: a fixed-size dark-grey rectangle with a light-grey border. Click (or press
    /// "e" with the list selected) opens the None / INT / EXT / INT/EXT chooser as a popover
    /// anchored here. "INT/EXT" is stacked (INT over EXT) so the chip stays compact and its width
    /// never changes with the choice; unset shows a dimmed "INT/EXT" placeholder. It's a plain
    /// Button (not a Menu) because `.menuStyle(.borderlessButton)` ignored the label's font/frame/
    /// border — so the stacked text and outline weren't rendering.
    private var sceneTypeMenu: some View {
        Button {
            sceneTypeEditID?.wrappedValue = list.uuid
        } label: {
            sceneTypeLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: sceneTypePopoverBinding, arrowEdge: .top) {
            SceneTypePickerSheet(
                current: list.sceneType,
                onPick: { newType in
                    list.sceneType = newType
                    try? modelContext.save()
                    sceneTypeEditID?.wrappedValue = nil
                },
                onDismiss: { sceneTypeEditID?.wrappedValue = nil }
            )
        }
    }

    /// True when this row is the scene-type edit target (drives its popover).
    private var sceneTypePopoverBinding: Binding<Bool> {
        Binding(
            get: { sceneTypeEditID?.wrappedValue == list.uuid },
            set: { if !$0 { sceneTypeEditID?.wrappedValue = nil } }
        )
    }

    @ViewBuilder
    private var sceneTypeLabel: some View {
        let isStacked = (list.sceneType == nil || list.sceneType == "INT/EXT")
        // Placeholder (unset) is dimmer than a set value, but still visible in dark mode.
        let textColor = list.sceneType == nil ? Color(white: 0.6) : Color(white: 0.95)
        Group {
            if isStacked {
                // INT over EXT, each at ~half height so the pair stacks within a single line.
                VStack(spacing: -2) {
                    Text("INT")
                    Text("EXT")
                }
                .font(.system(size: 7, weight: .bold))
            } else {
                Text(list.sceneType ?? "")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .lineLimit(1)
        .foregroundStyle(textColor)
        .frame(width: 34, height: 22)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.32)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.72), lineWidth: 1))
    }

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

            // Color dot (or folder icon).
            if isFolder {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Circle()
                    .fill(listColor)
                    .frame(width: 10, height: 10)
            }

            // Screenplay scene type (INT / EXT / INT/EXT), pickable via menu. Sits between the
            // dot and the title. Kept out of the drag handle so a click opens the menu rather
            // than starting a reorder drag.
            sceneTypeMenu
                .padding(.horizontal, 5)

            // Drag handle: the list name initiates a reorder drag.
            Text(list.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .modifier(OptionalDrag(provider: dragProvider))

            Spacer()

            // Order (left→right): flag, scene badge, count, eye.
            // A flag here means at least one photo in the list is flagged — i.e. a filming
            // location has already been picked for this list.
            if ListRow.hasFlagged(list) {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            // Scene indicator: this list has script scene(s) assigned. Click → open the script at
            // the first one (same as clicking the list's scene row).
            if !list.sceneLinks.isEmpty {
                Button {
                    if let first = list.sceneLinks.sorted(by: { $0.rangeStart < $1.rangeStart }).first {
                        onOpenSceneLink?(first)
                    }
                } label: {
                    HStack(spacing: 1) {
                        Image(systemName: "text.quote")
                        Text("\(list.sceneLinks.count)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Count only LIVE photos (and live child lists), recursively — trashed photos
            // stay in `list.pins` (soft-delete just sets deletedAt), so counting them made
            // the header number exceed what's actually shown in the sidebar/grid/map.
            let pinCount = ListRow.liveCount(list)
            if pinCount > 0 {
                Text("\(pinCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                let optionHeld = currentModifierFlags().option
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
        .onTapGesture { { let m = currentModifierFlags(); onTap?(m.shift, m.option) }() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        .contextMenu {
            Button { onRename?() } label: {
                Label("Rename List", systemImage: "pencil")
            }
            if let onFitToList {
                Button {
                    let allPins = list.pins.filter { $0.hasGPS }
                        + list.childLists.flatMap { $0.pins.filter { $0.hasGPS } }
                    onFitToList(allPins)
                } label: {
                    Label("Fit Map to List", systemImage: "mappin.and.ellipse")
                }
            }
            // Unnest a folder child back to the top level. (Nesting is drag-only.)
            if isNested {
                Divider()
                Button { onMoveToTopLevel?() } label: {
                    Label("Move to Top Level", systemImage: "arrow.up.to.line")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete?()
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
    @ObservedObject var selection: SelectionStore
    var listColor: Color? = nil
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    private var isSelected: Bool { selection.contains(pin.uuid) }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
            // Flagged (favorite filming location) marker.
            if pin.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.trailing, 4)
            }
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
        .onTapGesture { { let m = currentModifierFlags(); onTap?(m.shift, m.option) }() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        // NOTE: no .contextMenu here — each pin row attaches the shared `pinContextMenu(pin)`
        // from ProjectDetailView (which has access to flag/delete). An inner menu here would
        // shadow it.
    }

    @ViewBuilder
    private var thumbnail: some View {
        let url: URL? = pin.thumbnailImages.first?.url
            ?? pin.photoFiles.first.map { PinPhotoStore.fileURL($0) }
            ?? pin.imageURL.flatMap { URL(string: $0) }
        if let url {
            // GooglePhotoImage uses PhotoLoader's shared NSCache — thumbnails are decoded
            // once and reused on scroll, unlike AsyncImage which has no cache.
            GooglePhotoImage(url: url, rotationQuarterTurns: pin.rotationQuarterTurns) {
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
    var confirmLabel: String = "Create"
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
                Button(confirmLabel) { onConfirm(text) }
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

// ⚠️⚠️ DO NOT BREAK THE SEARCH IN THIS VIEW ⚠️⚠️
// The live search here was broken for many debugging rounds. There are THREE separate
// macOS/SwiftUI footguns that each independently break it — all are avoided below, and
// changing any of them brings the bug back (you type "temple" and get an unrelated list):
//
//   1. ForEach row identity MUST be `id: \.persistentModelID` ONLY. Do NOT also put
//      `.id(idx)` (or any index-based id) on the row. Two competing identities make
//      SwiftUI reuse the row at a given position and keep showing STALE content when the
//      filtered array changes. (This was the final root cause.)
//   2. Do NOT attach `.onKeyPress` to the search TextField. On macOS it intercepts the key
//      path so characters draw in the field but the `text` binding stops updating live —
//      `query` stays "" and nothing filters. Arrow/escape are handled by hidden
//      keyboardShortcut buttons in `.background` instead (see body).
//   3. Read lists from `project.lists` (the forward relationship the sidebar uses), NOT a
//      `@Query` filtered by the `.project` inverse — that inverse isn't reliably set on
//      every list, so the fetch returns a different/partial set.
//
// If you touch this view, re-test: open the M-menu, type a substring of a known list name,
// and confirm ONLY matching lists show, live, on every keystroke.
struct MoveToListSheet: View {
    let project: ProjectData
    let onMove: (LocationListData) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var projectLists: [LocationListData] {
        // Use the project.lists forward relationship — the exact same source the
        // sidebar uses — sorted to match sidebar order (panelOrder, then createdAt).
        // Trashed lists are excluded so you can't move photos into a deleted list.
        project.lists.filter { $0.deletedAt == nil }.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    private var filtered: [LocationListData] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return projectLists }
        return projectLists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// The currently highlighted list (clamped), or nil when there are no results.
    private var highlightedList: LocationListData? {
        guard !filtered.isEmpty else { return nil }
        return filtered[min(max(highlighted, 0), filtered.count - 1)]
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
                            // Identity is the list's persistentModelID ONLY. A previous
                            // version also set .id(idx), which conflicted with the ForEach
                            // identity and made SwiftUI keep showing a stale row's content
                            // when the filter narrowed — that was the M-menu search bug.
                            ForEach(filtered, id: \.persistentModelID) { list in
                                let isHi = highlightedList?.persistentModelID == list.persistentModelID
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(hexString: list.colorHex))
                                        .frame(width: 9, height: 9)
                                    Text(list.name)
                                        .font(.subheadline)
                                    Spacer()
                                    if isHi {
                                        Image(systemName: "return")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(isHi ? Color.accentColor.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                                .onTapGesture { onMove(list) }
                                // ⚠️ Keep this as persistentModelID. NEVER add `.id(idx)` —
                                // see the warning above the struct. It breaks live search.
                                .id(list.persistentModelID)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: highlighted) { _, _ in
                        if let hl = highlightedList {
                            withAnimation { proxy.scrollTo(hl.persistentModelID, anchor: .center) }
                        }
                    }
                    // Cap the scroll area so a long list can't make the sheet taller than the
                    // window — a too-tall .sheet forces macOS to grow the window (and it never
                    // shrinks back). Short lists still size to content via the outer fixedSize.
                    .frame(maxHeight: 320)
                }
            }
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        // Arrow/escape handled by hidden keyboardShortcut buttons rather than
        // .onKeyPress on the TextField — on macOS, attaching .onKeyPress to a
        // focused TextField intercepts the key path and stops the text binding from
        // updating live, which silently broke the search filtering. Letter keys flow
        // straight to the field editor here, so `query` updates on every keystroke.
        .background {
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0).allowsHitTesting(false)
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0).allowsHitTesting(false)
            Button("") { onDismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).allowsHitTesting(false)
        }
        .onAppear {
            highlighted = 0
            // Async focus: in a sheet the window isn't key yet during onAppear, so
            // setting @FocusState synchronously shows a caret but the field never
            // actually becomes first responder — keystrokes get dropped. Defer it.
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onChange(of: query) { highlighted = 0 }
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

/// Compact, keyboard-navigable scene-type chooser (None / INT / EXT / INT/EXT). Opened by pressing
/// "e" with a list selected; ↑/↓ to move, Return to apply, Esc to cancel.
struct SceneTypePickerSheet: View {
    let current: String?
    let onPick: (String?) -> Void
    let onDismiss: () -> Void

    private let options: [String?] = [nil, "INT", "EXT", "INT/EXT"]
    @State private var highlighted = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("Scene Type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            VStack(spacing: 2) {
                ForEach(options.indices, id: \.self) { idx in
                    let opt = options[idx]
                    let isHi = idx == highlighted
                    HStack(spacing: 8) {
                        Text(opt ?? "None").font(.subheadline)
                        Spacer()
                        if current == opt {
                            Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
                        }
                        if isHi {
                            Image(systemName: "return").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(isHi ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { onPick(opt) }
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            Button("") { move(1) }.keyboardShortcut(.downArrow, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { move(-1) }.keyboardShortcut(.upArrow, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { onPick(options[highlighted]) }.keyboardShortcut(.return, modifiers: []).opacity(0).allowsHitTesting(false)
            Button("") { onDismiss() }.keyboardShortcut(.escape, modifiers: []).opacity(0).allowsHitTesting(false)
        }
        .onAppear { highlighted = options.firstIndex(where: { $0 == current }) ?? 0 }
    }

    private func move(_ delta: Int) {
        highlighted = (highlighted + delta + options.count) % options.count
    }
}

// MARK: - Previews

#if DEBUG
/// Rich in-memory sample data for the sidebar previews: one project with several
/// colour-coded lists (each holding a few photos), some uncategorised photos, and a
/// couple of trashed photos so the Trash section shows too.
@MainActor
private enum SidebarPreviewData {
    /// A handful of Creative-Commons image URLs so thumbnails render when online
    /// (they fall back to the mappin placeholder offline — layout still looks right).
    nonisolated static let imageURLs = [
        "https://upload.wikimedia.org/wikipedia/commons/thumb/3/30/Vasquez_Rocks_2013.jpg/320px-Vasquez_Rocks_2013.jpg",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a3/Vasquez_Rocks_County_Park_2.jpg/320px-Vasquez_Rocks_County_Park_2.jpg",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5e/Vasquez_Rocks.jpg/320px-Vasquez_Rocks.jpg",
        "https://upload.wikimedia.org/wikipedia/commons/thumb/c/c5/Tokyo_Tower_and_around_Skyscrapers.jpg/320px-Tokyo_Tower_and_around_Skyscrapers.jpg",
    ]

    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: ProjectData.self, LocationListData.self, PinnedLocationData.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let project = ProjectData(name: "Tokyo Shoot")
        ctx.insert(project)

        // Builds a pin with a thumbnail URL and a GPS coordinate.
        func makePin(_ name: String, urlIndex: Int, lat: Double, lng: Double, order: Int) -> PinnedLocationData {
            let loc = ScoutLocation(
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                images: [ScoutImage(url: URL(string: imageURLs[urlIndex % imageURLs.count]), source: .imported)]
            )
            let pin = PinnedLocationData(from: loc, sortOrder: order)
            ctx.insert(pin)
            return pin
        }

        // Colour-coded lists (palette indices chosen for variety), each with a few photos.
        let listSpecs: [(name: String, palette: Int)] = [
            ("Cycling Roads", 1),     // blue
            ("Temples", 3),           // purple
            ("Abandoned Houses", 4),  // pink
            ("Tea Farms", 2),         // green
        ]
        for (i, spec) in listSpecs.enumerated() {
            let list = LocationListData(name: spec.name, colorHex: LocationListData.palette[spec.palette])
            ctx.insert(list)
            list.project = project              // inverse populates project.lists
            list.panelOrder = i
            for j in 0..<3 {
                let pin = makePin("\(spec.name) \(j + 1)", urlIndex: i + j,
                                  lat: 35.66 + Double(i) * 0.01, lng: 139.70 + Double(j) * 0.01, order: j)
                pin.list = list                 // inverse populates list.pins
            }
        }

        // Loose, uncategorised photos imported straight into the project.
        for k in 0..<4 {
            let pin = makePin("DSC0\(2530 + k)", urlIndex: k, lat: 35.64, lng: 139.74, order: k)
            pin.owningProject = project          // inverse populates project.importedPhotos
            pin.panelOrder = 100 + k
        }

        // A couple of trashed photos so the Trash section appears.
        for k in 0..<2 {
            let pin = makePin("DSC0\(2999 - k)", urlIndex: k, lat: 35.63, lng: 139.73, order: k)
            pin.owningProject = project
            pin.deletedAt = Date()
        }

        try? ctx.save()
        return container
    }()

    static var project: ProjectData {
        (try? container.mainContext.fetch(FetchDescriptor<ProjectData>()))?.first
            ?? ProjectData(name: "Empty")
    }
}

/// Hosts ProjectDetailView with live @State bindings and turns every list's eye on so
/// the preview shows a fully-populated, expanded sidebar.
private struct SidebarDetailPreview: View {
    let project: ProjectData
    @State private var activeListIDs: Set<PersistentIdentifier> = []
    @State private var hiddenUncategorizedProjectIDs: Set<PersistentIdentifier> = []
    @State private var externalMoveUUIDs: [UUID] = []

    var body: some View {
        ProjectDetailView(
            project: project,
            selection: SelectionStore(),
            initialExpandedUUIDs: Set(project.lists.map(\.uuid.uuidString)),
            activeListIDs: $activeListIDs,
            hiddenUncategorizedProjectIDs: $hiddenUncategorizedProjectIDs,
            onFitToList: { _ in },
            onSelectPin: { _ in },
            onZoomToPin: { _ in },
            onClearPin: {},
            externalMoveUUIDs: $externalMoveUUIDs
        )
        .onAppear { activeListIDs = Set(project.lists.map(\.persistentModelID)) }
    }
}

#Preview("Project detail — full") {
    SidebarDetailPreview(project: SidebarPreviewData.project)
        .frame(width: 280, height: 760)
        .modelContainer(SidebarPreviewData.container)
}

#Preview("Projects list") {
    ProjectsPanel(selection: SelectionStore(), activeListIDs: .constant([]), hiddenUncategorizedProjectIDs: .constant([]), externalMoveUUIDs: .constant([]))
        .frame(width: 280, height: 600)
        .modelContainer(SidebarPreviewData.container)
}
#endif

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

// MARK: - Scrollbar gutter

#if os(macOS)
/// Forces the enclosing List's NSScrollView to use overlay scrollers (which never push
/// content) and reserves a constant right-hand content inset, so row width stays identical
/// whether or not the scrollbar is showing. Fixes the layout jump on long lists.
private struct ScrollerGutterReserver: NSViewRepresentable {
    var width: CGFloat = 14

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in apply(from: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(from: nsView) }
    }

    private func apply(from view: NSView?) {
        guard let view, let scroll = findScrollView(from: view) else { return }
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        // Keep the scroller permanently present. When the system uses legacy (in-line)
        // scrollers — "Always" in System Settings, or whenever a mouse is attached — an
        // autohiding scroller pops in on scroll and steals width from the rows, squeezing
        // them. Pinning it on means the content width never changes.
        scroll.autohidesScrollers = false
        scroll.automaticallyAdjustsContentInsets = false
        let cur = scroll.contentInsets
        guard cur.right != width else { return }
        scroll.contentInsets = NSEdgeInsets(top: cur.top, left: cur.left, bottom: cur.bottom, right: width)
    }

    /// Walks up from the background view, scanning each ancestor's subtree for the table's
    /// scroll view. The nearest match is the sidebar List's scroll view.
    private func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = firstTableScrollView(in: v) { return sv }
            current = v.superview
        }
        return nil
    }

    private func firstTableScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
        for sub in view.subviews {
            if let found = firstTableScrollView(in: sub) { return found }
        }
        return nil
    }
}
#endif
