import SwiftUI
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

/// Deletes EVERY project, list, and pin in the store, logging counts before and after.
/// Must be called only after any open-project detail view has been popped/unmounted (see the
/// purgeTrigger handler), so no @ObservedObject view is bound to a model being deleted.
@MainActor
func purgeAllProjects() {
    let mac = MacStore.shared
    DebugLogger.shared.log("--- BEFORE PURGE ---", level: .warning, tag: "Purge")
    DebugLogger.shared.log("Projects (\(mac.projects.count)):", level: .info, tag: "Purge")
    for p in mac.projects {
        DebugLogger.shared.log("  📁 \"\(p.name)\" — \(p.lists.count) lists, \(p.importedPhotos.count) photos", level: .info, tag: "Purge")
        for list in p.lists {
            DebugLogger.shared.log("    📋 \"\(list.name)\" — \(list.pins.count) pins", level: .info, tag: "Purge")
        }
    }
    // FK cascade removes lists/pins/scripts; purge each project through the store.
    let ids = mac.projects.map(\.id)
    Task {
        for id in ids { try? await ScoutStore.shared.purgeProject(id: id) }
        DebugLogger.shared.log("--- PURGE COMPLETE (\(ids.count) projects) ---", level: .success, tag: "Purge")
    }
}

// MARK: - Projects panel

struct ProjectsPanel: View {
    @EnvironmentObject private var auth: AuthManager
    @State private var showSignOutConfirm = false
    /// Store-backed VM graph (PowerSync) — replaces the Core Data @FetchRequests. Same-named
    /// computed properties keep the rest of the panel body unchanged.
    @ObservedObject private var mac = MacStore.shared
    private var projects: [ProjectVM] { mac.projects.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt } }
    private var trashedProjects: [ProjectVM] { mac.projects.filter { $0.deletedAt != nil }.sorted { $0.createdAt < $1.createdAt } }

    /// THE shared selection store (sidebar + grid + map), owned by ContentView.
    var selection: SelectionStore
    @Binding var activeListIDs: Set<String>
    /// Projects whose uncategorized (loose) photos are hidden from map + grid.
    @Binding var hiddenUncategorizedProjectIDs: Set<String>
    /// Toggled by the debug "Clear Old Lists" button. Flipping it runs the full purge
    /// here (where navPath lives) so nav-pop + delete happen in one atomic transaction.
    var purgeTrigger: Bool = false
    var onFitToList: (([PinVM]) -> Void)? = nil
    var onSelectPin: ((PinVM) -> Void)? = nil
    var onZoomToPin: ((PinVM) -> Void)? = nil
    var onClearPin: (() -> Void)? = nil
    var onRevealPins: (([PinVM]) -> Void)? = nil
    var onOpenCarousel: ((PinVM) -> Void)? = nil
    /// Opens a script in the Script view (third island mode).
    var onOpenScript: ((ScriptVM) -> Void)? = nil
    /// Opens a script scene (highlight) in the Script view, scrolled to its range.
    var onOpenScriptHighlight: ((HighlightVM) -> Void)? = nil
    /// Selecting a list while the Script view is open scrolls the script to that list's scene
    /// (ContentView gates on viewMode). No-op when not in script view or the list has no scene link.
    var onSelectListForScript: ((ListVM) -> Void)? = nil
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

    /// Persisted open project (stored as UUID string, resolved to ProjectVM on load).
    @AppStorage("nav.openProjectUUID") private var openProjectUUID: String = ""
    /// Persisted expanded list UUIDs, comma-separated.
    @AppStorage("nav.expandedListUUIDs") private var expandedListUUIDs: String = ""

    @State private var navPath: [ProjectVM] = []
    @State private var showAddProject = false
    @State private var newProjectName = ""
    @State private var renamingProject: ProjectVM? = nil
    @State private var renameText = ""
    @State private var expandedProjectTrash = false
    @State private var showEmptyProjectTrashConfirm = false
    /// Project highlighted by a single click. Single click only selects; double click opens.
    @State private var selectedProjectID: String? = nil

    var body: some View {
        NavigationStack(path: $navPath) {
            projectList
                .navigationDestination(for: ProjectVM.self) { project in
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
                        onSelectListForScript: onSelectListForScript,
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
                purgeAllProjects()
            }
        }
        .sheet(isPresented: $showAddProject) {
            NameEntrySheet(
                title: "New Project",
                placeholder: "Project name",
                text: $newProjectName,
                onDismiss: { showAddProject = false }
            ) { name in
                Task { try? await ScoutStore.shared.createProject(name: name) }
                showAddProject = false
            }
        }
    }

    private var storedExpandedUUIDs: Set<String> {
        Set(expandedListUUIDs.split(separator: ",").map(String.init))
    }

    @ViewBuilder
    private func projectRow(_ project: ProjectVM) -> some View {
        let isSelected = selectedProjectID == project.id
        let listCount = project.liveLists.count
        let photoCount = project.livePhotos.count
        VStack(alignment: .leading, spacing: 2) {
            Text(project.name).font(.headline)
            if listCount + photoCount > 0 {
                Text("\(listCount) lists · \(photoCount) photos")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .onTapGesture { selectedProjectID = project.id }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selectedProjectID = project.id
            navPath = [project]
        })
        .listRowBackground(Color.clear)
        .contextMenu {
            Button {
                renameText = project.name
                renamingProject = project
            } label: { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) {
                if navPath.first?.id == project.id {
                    navPath = []
                    openProjectUUID = ""
                    expandedListUUIDs = ""
                }
                project.deletedAt = Date()   // write-through soft-delete (Trash)
            } label: { Label("Move to Trash", systemImage: "trash") }
        }
    }

    private var projectList: some View {
        List {
            Color.clear.frame(height: sidebarTopPadding).listRowBackground(Color.clear)
            ForEach(projects) { project in
                projectRow(project)
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
            // Sign out — only when cloud auth is actually on (hidden in local-only mode).
            if !auth.authDisabled {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSignOutConfirm = true } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                    .help(auth.userEmail.map { "Sign out (\($0))" } ?? "Sign out")
                }
            }
        }
        .confirmationDialog("Sign out\(auth.userEmail.map { " of \($0)" } ?? "")?",
                            isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await auth.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your synced data stays in the cloud and returns when you sign back in.")
        }
        .alert("Rename Project", isPresented: Binding(
            get: { renamingProject != nil },
            set: { if !$0 { renamingProject = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { renamingProject?.name = trimmed }
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

    private func trashedProjectRow(_ project: ProjectVM) -> some View {
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
    private func purgeProject(_ project: ProjectVM) {
        if navPath.first?.id == project.id {
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

    private func hardDeleteProject(_ project: ProjectVM) {
        // Postgres FK cascade reaches lists/pins/scripts/highlights; purgeProject also deletes the
        // whole subtree locally so the device matches immediately.
        let id = project.id
        Task { try? await ScoutStore.shared.purgeProject(id: id) }
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

@MainActor
enum SidebarItem: Identifiable {
    case photo(PinVM)
    case list(ListVM)
    /// The virtual "Uncategorized" row — a reorderable, collapsible top-level pseudo-list
    /// that holds every loose photo (no list). Identified by its owning project.
    case uncategorized(ProjectVM)

    var id: String {
        switch self {
        case .photo(let p): return p.id
        case .list(let l): return l.id
        case .uncategorized(let proj): return proj.id
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
enum DropMode { case before, into, after }

/// Drop delegate that maps the cursor's vertical position within a row to a drop zone. Rows
/// that accept nesting (lists) carve out a center "into" band; all rows have before/after
/// edge bands for reordering. Reports the live zone for preview and performs the drop.
struct SidebarRowDropDelegate: DropDelegate {
    let targetID: String
    let allowNest: Bool
    let height: () -> CGFloat
    let onTargetChange: (String?, DropMode) -> Void
    /// Clear the highlight only if this row still owns it — avoids a race where the old row's
    /// dropExited fires after the new row's dropEntered and wipes the fresh target.
    let onExit: (String) -> Void
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

struct ProjectDetailView: View {
    @ObservedObject var project: ProjectVM
    /// THE shared selection store (sidebar + grid + map). Held as a plain `var` (NOT
    /// @ObservedObject) so mutating it never re-runs THIS view's body / its ForEach — only the
    /// PinRow/ListRow leaves observe it and repaint. Observing it here would rebuild the whole
    /// list on every click (the documented sidebar-selection perf footgun).
    var selection: SelectionStore
    var initialExpandedUUIDs: Set<String> = []
    @Binding var activeListIDs: Set<String>
    @Binding var hiddenUncategorizedProjectIDs: Set<String>
    var onFitToList: (([PinVM]) -> Void)?
    var onSelectPin: ((PinVM) -> Void)?
    var onZoomToPin: ((PinVM) -> Void)?
    var onClearPin: (() -> Void)?
    var onRevealPins: (([PinVM]) -> Void)? = nil
    var onOpenCarousel: ((PinVM) -> Void)? = nil
    var onOpenScript: ((ScriptVM) -> Void)? = nil
    var onOpenScriptHighlight: ((HighlightVM) -> Void)? = nil
    var onSelectListForScript: ((ListVM) -> Void)? = nil
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

    @State var showAddList = false
    @State var newListName = ""
    /// Global "show flagged only" filter — shared with the grid/map via AppStorage.
    @AppStorage("filter.flaggedOnly") var flaggedOnly = false
    @State var expandedListIDs: Set<String> = []
    // Whether the Uncategorized pseudo-list is expanded to show its loose photos.
    @State var uncategorizedExpanded = false
    // Whether the "Scripts" pseudo-list is expanded to show imported scripts.
    @State var scriptsExpanded = false
    @State var renamingList: ListVM? = nil
    @State var renameListText = ""
    @State var isBackfilling = false
    @State var showMovePopup = false
    /// The list whose scene-type popover is open (anchored to its row), or nil. Set by pressing "e".
    @State var sceneTypeEditID: UUID? = nil
    @State var searchText = ""
    @State var importProgress: (label: String, current: Int, total: Int)? = nil
    @State var timelineProgress: (current: Int, total: Int, name: String)? = nil
    // Selection lives in a reference-type model owned via plain @State (NOT @StateObject),
    // so mutating it never re-renders this view or re-runs ForEach(sidebarItems). Only the
    // handful of on-screen rows observe it via @ObservedObject, so selecting (or shift-
    // selecting thousands of) rows repaints only what's visible — instant regardless of count.
    // Cached sidebar items — rebuilt only when photos/lists actually change,
    // not on every render triggered by selection or scroll state.
    @State var cachedSidebarItems: [SidebarItem] = []
    // Held so moveSelection can scroll without needing to be inside the ScrollViewReader body.
    // Stored in a reference box (not a plain @State ScrollViewProxy?) so body can stash the proxy
    // without "Modifying state during view update" — mutating a property of a stable class
    // instance is not a SwiftUI state change, and we never want stashing it to trigger a re-render.
    final class ProxyBox { var proxy: ScrollViewProxy? }
    @State var listProxyBox = ProxyBox()
    // Undo stack of trashed-photo batches (each batch = the persistent ids trashed together).
    // ⌘Z pops the last batch and restores those photos.
    @State var trashUndoStack: [[String]] = []
    @State var expandedTrash = false
    @State var expandedTrashListIDs: Set<String> = []
    // Lists awaiting a delete confirmation, plus any photos selected alongside them. A list is
    // never deleted without this confirm step; on confirm it (and its photos) go to the Trash.
    @State var listsPendingDelete: [ListVM] = []
    @State var pinsPendingDelete: [PinVM] = []
    @State var showDeleteListConfirm = false

    /// True whenever a sidebar text field is active (rename, new-list name, or the move popup's
    /// search). The bare-letter / Return key handlers must defer to it so typing isn't stolen.
    var isEditingListText: Bool {
        renamingList != nil || showAddList || showMovePopup
    }
    // Top-level row currently under a reorder drag — a blue insertion line is drawn at its
    // top edge to preview where the dragged item will land (it inserts before this row).
    @State var dropTargetID: String? = nil
    // Whether the current drag will reorder (line before/after the row) or nest into a list
    // (the whole row highlights). Decided from the cursor's vertical position within the row.
    @State var dropMode: DropMode = .before
    // Watchdog that clears the drop indicator shortly after drag activity stops — covers drags
    // that end outside any row (or are cancelled), where SwiftUI doesn't fire dropExited and the
    // mouse-up that ends a drag session isn't seen by the event monitor. Each drop update resets
    // it; AppKit fires periodic drag updates while a drag is live, so it only triggers once the
    // drag has actually ended.
    @State var dropClearWork: DispatchWorkItem? = nil
    // Measured heights per row so the drop delegate can map cursor-Y to a drop zone.
    @State var rowHeights: [String: CGFloat] = [:]
    // macOS mouse-event monitor that clears a stuck drop indicator. SwiftUI's DropDelegate
    // sometimes fails to deliver dropExited when a drag is cancelled, leaving the blue
    // insertion line on screen; releasing the mouse (or the next click) clears it here.
    #if os(macOS)
    @State var dragEndMonitor: Any? = nil
    #endif
    // True only while the user has clicked into the sidebar search field. Bare-letter
    // keys (e.g. the "m" Move shortcut) must not be swallowed by the field unless it's
    // actually focused, so we resign this whenever a row is selected.
    @FocusState var searchFieldFocused: Bool

    /// One flat, ordered entry per visible row. Carries both the `uuid` (the selection key,
    /// shared with the grid and map) and the `scrollID` (the row's ScrollViewReader identity,
    /// which is its String). Used for shift-range selection and arrow-key nav.
    struct FlatRow { let uuid: UUID; let scrollID: String }
    var flatVisibleRows: [FlatRow] {
        var result: [FlatRow] = []
        for item in cachedSidebarItems {
            switch item {
            case .photo(let pin):
                result.append(FlatRow(uuid: pin.uuid, scrollID: pin.id))
            case .list(let list):
                result.append(FlatRow(uuid: list.uuid, scrollID: list.id))
                if expandedListIDs.contains(list.id) {
                    for p in flaggedFirst(list.pins.filter { $0.deletedAt == nil }) {
                        result.append(FlatRow(uuid: p.uuid, scrollID: p.id))
                    }
                }
            case .uncategorized(let proj):
                result.append(FlatRow(uuid: proj.uuid, scrollID: proj.id))
                if uncategorizedExpanded {
                    for p in loosePhotos {
                        result.append(FlatRow(uuid: p.uuid, scrollID: p.id))
                    }
                }
            }
        }
        return result
    }

    /// Single click selects just this row (and fires the map side effect).
    /// Shift-click extends a contiguous range from the anchor.
    /// Option-click toggles this item in/out of a disparate selection.
    func handleTap(_ id: UUID, shift: Bool, option: Bool = false) {
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
            if activeListIDs.contains(list.id) {
                onClearPin?()
                // Exclude soft-deleted pins — they're hidden from the sidebar but still
                // attached to the list relationship; a trashed pin far from the cluster
                // would otherwise blow out the fit region (a phantom "ghost pin").
                onFitToList?(list.pins.filter { $0.hasGPS && $0.deletedAt == nil })
            }
            // While the Script view is open, also scroll it to this list's scene (ContentView
            // checks viewMode + whether the list actually has a scene link).
            onSelectListForScript?(list)
        }
    }

    /// Double-click zooms into a pin (or fits to a list). No-GPS pins open in carousel.
    func handleDoubleTap(_ id: UUID) {
        if let pin = findPin(uuid: id) {
            if pin.hasGPS {
                onZoomToPin?(pin)
            } else {
                onOpenCarousel?(pin)
            }
        } else if let list = findList(uuid: id) {
            // Double-click toggles the list's visibility (eye on/off).
            if activeListIDs.contains(list.id) {
                // Toggling OFF — just hide this one.
                activeListIDs.remove(list.id)
            } else {
                // Toggling ON — "solo" this list. Hide every OTHER top-level list/folder,
                // keeping only this list's own top-level ancestor. Other folders are flipped
                // at the top-level gate; their nested children keep their own eye state.
                var topAncestor = list
                while let parent = topAncestor.parentList { topAncestor = parent }
                for top in project.lists where top.parentList == nil {
                    if top.id == topAncestor.id {
                        activeListIDs.insert(top.id)
                    } else {
                        activeListIDs.remove(top.id)
                    }
                }
                // If this list lives inside a folder, also hide its sibling lists so only
                // this one shows within the folder; its folder is made visible below.
                if let folder = list.parentList {
                    for sibling in folder.childLists where sibling.id != list.id {
                        activeListIDs.remove(sibling.id)
                    }
                }
                // Ensure the clicked list and its whole ancestor chain (folder) are active so
                // the folder visibility gate lets it show through. For a folder, also enable
                // its descendants so photos inside them are visible on the map/grid.
                var node: ListVM? = list
                while let n = node {
                    enableWithDescendants(n)
                    node = n.parentList
                }
                // Uncategorized is a top-level list too — hide it when soloing a real list.
                hiddenUncategorizedProjectIDs.insert(project.id)
            }
        }
    }

    /// Double-click on the Uncategorized row: toggle its visibility, soloing it (hide every
    /// top-level list) when turning on — exactly how double-clicking a normal list behaves.
    func handleUncategorizedDoubleTap() {
        if uncategorizedVisible {
            hiddenUncategorizedProjectIDs.insert(project.id)
        } else {
            for top in project.lists where top.parentList == nil {
                activeListIDs.remove(top.id)
            }
            hiddenUncategorizedProjectIDs.remove(project.id)
        }
    }

    /// Whether this project's uncategorized (loose) photos are shown on map + grid.
    var uncategorizedVisible: Bool {
        !hiddenUncategorizedProjectIDs.contains(project.id)
    }

    /// True when every list and the uncategorized photos are currently visible.
    var allListsVisible: Bool {
        project.lists.allSatisfy { activeListIDs.contains($0.id) } && uncategorizedVisible
    }

    /// Master visibility row at the top of the sidebar: one eye that shows/hides everything,
    /// aligned with the per-row eyes. Same effect as Option-clicking any row's eye.
    var masterVisibilityRow: some View {
        HStack {
            Text("All Lists")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button { setProjectVisibility(!allListsVisible) } label: {
                Image(systemName: allListsVisible ? "eye.fill" : "eye")
                    .foregroundStyle(allListsVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(allListsVisible ? "Hide all" : "Show all")
        }
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .contentShape(Rectangle())
    }

    /// Recursively enables a list and all its descendants in activeListIDs.
    /// Required when turning a folder on: the parent-gate in isEffectivelyActive means
    /// a child list won't show on the map/grid unless BOTH it AND the folder are active.
    func enableWithDescendants(_ list: ListVM) {
        activeListIDs.insert(list.id)
        for child in list.childLists { enableWithDescendants(child) }
    }

    /// Toggles every list AND the uncategorized photos in this project on/off at once.
    /// Used by Option-clicking any eye.
    func setProjectVisibility(_ visible: Bool) {
        let pid = project.id
        if visible {
            project.lists.forEach { activeListIDs.insert($0.id) }
            hiddenUncategorizedProjectIDs.remove(pid)
        } else {
            project.lists.forEach { activeListIDs.remove($0.id) }
            hiddenUncategorizedProjectIDs.insert(pid)
        }
    }

    /// Moves keyboard selection up (-1) or down (+1) through the flat visible row list.
    /// If the next item is a list, it auto-expands it and steps inside to its first pin.
    func moveSelection(_ delta: Int) {
        let flat = flatVisibleRows
        guard !flat.isEmpty else { return }
        let current = selection.anchor ?? flat.first!.uuid
        guard let idx = flat.firstIndex(where: { $0.uuid == current }) else { return }
        var next = max(0, min(flat.count - 1, idx + delta))

        // If the target is a collapsed list and we're moving into it, expand it first
        // and step to its first pin (or last pin when moving up).
        let targetUUID = flat[next].uuid
        if let list = cachedSidebarItems.compactMap({ item -> ListVM? in
                if case .list(let l) = item { return l } else { return nil }
            }).first(where: { $0.uuid == targetUUID }),
           !expandedListIDs.contains(list.id) {
            let pins = flaggedFirst(list.pins.filter { $0.deletedAt == nil })
            if !pins.isEmpty {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) { _ = expandedListIDs.insert(list.id) }
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
        // Scroll by the row's ScrollViewReader identity (String), not the uuid.
        listProxyBox.proxy?.scrollTo(target.scrollID, anchor: .none)
    }

    func rebuildSidebarItems() {
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
            // Uncategorized always sorts last (just above the Scripts section), regardless of
            // its panelOrder; real lists keep their panelOrder ordering among themselves.
            switch ($0, $1) {
            case (.uncategorized, _): return false
            case (_, .uncategorized): return true
            default:
                return $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
            }
        }
    }

    /// This project's live (non-trashed) loose photos — the contents of Uncategorized.
    var loosePhotos: [PinVM] {
        project.importedPhotos
            .filter { $0.deletedAt == nil }
            .sorted { $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt }
    }

    // Use cachedSidebarItems everywhere the old sidebarItems was used.
    var sidebarItems: [SidebarItem] { cachedSidebarItems }

    // MARK: - Folder nesting

    func nestList(_ list: ListVM, into folder: ListVM) {
        Task { try? await ScoutStore.shared.setListParent(id: list.id, parentListId: folder.id) }
        rebuildSidebarItems()
    }

    func unnestList(_ list: ListVM) {
        Task { try? await ScoutStore.shared.setListParent(id: list.id, parentListId: nil) }
        rebuildSidebarItems()
    }

    /// Drop handler for child-list rows inside a folder. Handles BOTH:
    ///  • photo(s)/pin dropped INTO the child list (mode `.into`) → move them into it, and
    ///  • a sibling child list reordered before/after (mode `.before`/`.after`).
    /// External files/images are imported into the child list when dropped onto it.
    func performChildRowDrop(_ providers: [NSItemProvider], folder: ListVM,
                                      target child: ListVM, mode: DropMode) -> Bool {
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
    func reorderChild(_ dragged: ListVM, in folder: ListVM,
                               before target: ListVM, after: Bool) {
        var children = folder.childLists.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
        guard let from = children.firstIndex(where: { $0.id == dragged.id }),
              dragged.id != target.id else { return }
        let moving = children.remove(at: from)
        guard let to = children.firstIndex(where: { $0.id == target.id }) else { return }
        children.insert(moving, at: after ? to + 1 : to)
        for (i, child) in children.enumerated() { child.panelOrder = i }
    }


    /// Assigns sequential panelOrder values. Debounced so rapid imports (200 photos)
    /// don't fire 200 consecutive full-list writes.
    func normalizeOrder() {
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
    func resolve(_ dragID: String) -> SidebarItem? {
        cachedSidebarItems.first { $0.dragID == dragID }
    }

    /// Finds a pin anywhere in the project — top-level or inside any list.
    func findPin(uuid: String) -> PinVM? {
        if let p = project.importedPhotos.first(where: { $0.uuid.uuidString == uuid }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.uuid.uuidString == uuid }) { return p }
        }
        return nil
    }

    /// UUID overload — pins are selected by their stable `uuid` (the shared selection key).
    func findPin(uuid: UUID) -> PinVM? {
        if let p = project.importedPhotos.first(where: { $0.uuid == uuid }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.uuid == uuid }) { return p }
        }
        return nil
    }

    /// Lists currently selected in the sidebar (the shared selection holds list uuids too),
    /// excluding trashed lists. Drives the "e" scene-type shortcut.
    var selectedLists: [ListVM] {
        selection.ids.compactMap { findList(uuid: $0) }.filter { $0.deletedAt == nil }
    }

    /// Finds a list/folder anywhere in the project by its `uuid`.
    func findList(uuid: UUID) -> ListVM? {
        project.lists.first(where: { $0.uuid == uuid })
    }

    /// "Reveal in List": expand the pin's whole list/folder ancestor chain (so its row exists),
    /// select/highlight it, and scroll the sidebar to it.
    /// Scrolls the sidebar list to a row, retrying since freshly-expanded rows are lazy.
    func scrollSidebar(to target: String, using proxy: ScrollViewProxy) {
        for delay in [0.1, 0.35, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// Expands ONLY the revealed pin's list/folder chain (collapsing every other list), selects
    /// it, and returns its scroll id (the caller scrolls to it via the ScrollViewReader proxy).
    @discardableResult
    func revealPin(_ uuid: UUID) -> String? {
        guard let pin = findPin(uuid: uuid) else { return nil }
        // A sidebar search filter can hide the pin's row entirely — clear it so the row exists.
        if !searchText.isEmpty { searchText = "" }
        var tx = Transaction(animation: .none); tx.disablesAnimations = true
        withTransaction(tx) {
            if let list = pin.list {
                // Collapse everything else; expand ONLY this pin's list + ancestor folders.
                var chain = Set<String>()
                var node: ListVM? = list
                while let n = node { chain.insert(n.id); node = n.parentList }
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
        return pin.id
    }

    /// Expands a list's ancestor folder chain (so its row exists), selects it, and returns its
    /// scroll id — for revealing a list when its script highlight is clicked.
    @discardableResult
    func revealList(_ uuid: UUID) -> String? {
        guard let list = findList(uuid: uuid) else { return nil }
        if !searchText.isEmpty { searchText = "" }
        var tx = Transaction(animation: .none); tx.disablesAnimations = true
        withTransaction(tx) {
            var chain = Set<String>()
            var node: ListVM? = list.parentList
            while let n = node { chain.insert(n.id); node = n.parentList }
            expandedListIDs = chain
            uncategorizedExpanded = false
        }
        selection.ids = [list.uuid]
        selection.anchor = list.uuid
        return list.id
    }

    /// Flagged ("favorite filming location") pins first — keeping each group's sortOrder — so
    /// flagging a pin floats it to the top of its list, like pinning a chat.
    func flaggedFirst(_ pins: [PinVM]) -> [PinVM] {
        pins.sorted { a, b in
            a.isFlagged == b.isFlagged ? a.sortOrder < b.sortOrder : a.isFlagged
        }
    }

    /// Toggles the flagged state of `primary` (plus any other selected pins). If any are
    /// unflagged, flags them all; otherwise unflags them all.
    func toggleFlag(_ primary: PinVM) {
        var pins = [primary]
        if selection.contains(primary.uuid) {
            for id in selection.ids where id != primary.uuid {
                if let p = findPin(uuid: id) { pins.append(p) }
            }
        }
        let shouldFlag = pins.contains { !$0.isFlagged }
        for p in pins { p.isFlagged = shouldFlag }
    }


    var trimmedSearch: String { searchText.trimmingCharacters(in: .whitespaces) }
    func nameMatches(_ s: String) -> Bool {
        trimmedSearch.isEmpty || s.localizedCaseInsensitiveContains(trimmedSearch)
    }
    /// Sidebar items filtered by the search query (matches photo names; keeps lists that
    /// match by name or contain a matching photo).
    var displayedItems: [SidebarItem] {
        guard !trimmedSearch.isEmpty else { return sidebarItems }
        return sidebarItems.compactMap { item in
            switch item {
            case .photo(let p):
                return nameMatches(p.name) ? item : nil
            case .list(let list):
                if nameMatches(list.name) { return item }
                if list.livePins.contains(where: { nameMatches($0.name) }) { return item }
                // Also match if any child list name or its pins match.
                let childMatch = list.liveChildLists.contains {
                    nameMatches($0.name) || $0.livePins.contains { nameMatches($0.name) }
                }
                return childMatch ? item : nil
            case .uncategorized:
                // Keep Uncategorized visible while searching if any loose photo matches.
                return loosePhotos.contains { nameMatches($0.name) } ? item : nil
            }
        }
    }

    var sidebarSearchField: some View {
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
    func dropIndicator(for id: String) -> some View {
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
    func rowHeightReader(_ id: String) -> some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { rowHeights[id] = geo.size.height }
                .onChange(of: geo.size.height) { _, h in rowHeights[id] = h }
        }
    }

    /// Records the row currently under the drag and which zone (before/into/after) the cursor
    /// is in, so `dropIndicator` can preview the result.
    func setDropTarget(_ id: String?, mode: DropMode) {
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
    func clearDropTarget(ifOwnedBy id: String) {
        if dropTargetID == id { dropTargetID = nil }
    }

    /// Performs a row drop based on the resolved zone. `.into` a list nests a dragged list or
    /// moves a dragged photo into it; `.before`/`.after` reorder at the top level.
    func performRowDrop(target: SidebarItem, mode: DropMode, providers: [NSItemProvider]) -> Bool {
        // External files/images: import into the list when dropped onto it, else top-level.
        let importList: ListVM? = {
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
    func dispatchRowDrop(dragID: String, target: SidebarItem, mode: DropMode) {
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
                      dragged.id != folder.id else { return }
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
    func isDescendant(_ candidate: ListVM, of ancestor: ListVM) -> Bool {
        var node: ListVM? = candidate
        while let n = node {
            if n.id == ancestor.id { return true }
            node = n.parentList
        }
        return false
    }


    var body: some View {
        ScrollViewReader { listProxy in
        let _ = { listProxyBox.proxy = listProxy }()
        VStack(spacing: 0) {
        sidebarSearchField
        List {
            // Master visibility toggle — show/hide ALL lists + uncategorized at once (same as
            // Option-clicking any row's eye). Sits above the lists, below the search field.
            masterVisibilityRow

            ForEach(displayedItems) { item in
                sidebarRow(item)
            }

            // Scripts pinned at the bottom: below the lists, above Trash.
            scriptsSection

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
                                 .map(\.id)
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
                .filter { ids.contains($0.id) }
                .map(\.uuid.uuidString)
            onExpandedChanged?(uuids)
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
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
                // Show-only-flagged filter — applies everywhere (sidebar, grid, map).
                Button { flaggedOnly.toggle() } label: {
                    Image(systemName: flaggedOnly ? "flag.fill" : "flag")
                        .foregroundStyle(flaggedOnly ? .orange : .secondary)
                }
                .help(flaggedOnly ? "Showing flagged only — click to show all" : "Show flagged only")
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
                }
                renamingList = nil
            }
        }
        .confirmationDialog(
            "Move to Trash",
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
                let colorHex = ListVM.palette[project.lists.count % ListVM.palette.count]
                // Shift every existing item down to make room at the top (write-through).
                for existing in project.lists { existing.panelOrder += 1 }
                project.importedPhotos.forEach { $0.panelOrder += 1 }
                let pid = project.id
                Task { try? await ScoutStore.shared.createList(projectId: pid, name: name, colorHex: colorHex, panelOrder: 0) }
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
            listProxyBox.proxy?.scrollTo(pin.id, anchor: nil)
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
        .onKeyPress(.downArrow) { isEditingListText ? .ignored : { moveSelection(1); return .handled }() }
        .onKeyPress(.upArrow)   { isEditingListText ? .ignored : { moveSelection(-1); return .handled }() }
        // "e" with a list selected: open the scene-type chooser as a popover anchored to the row.
        // Lives here (not as a global keyboardShortcut) so a focused text field consumes "e"
        // normally — only fires when the sidebar itself has keyboard focus.
        .onKeyPress(KeyEquivalent("e")) {
            guard !isEditingListText, let target = selectedLists.first else { return .ignored }
            sceneTypeEditID = target.uuid
            return .handled
        }
        // Enter with a list selected: rename it (reuses the row's rename flow).
        .onKeyPress(.return) {
            guard !isEditingListText, let target = selectedLists.first else { return .ignored }
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
                ImportProgressOverlay(label: prog.label, current: prog.current, total: prog.total)
            } else if let prog = timelineProgress {
                TimelineProgressOverlay(current: prog.current, total: prog.total, currentName: prog.name)
            }
        }
    }
}
