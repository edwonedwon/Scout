import SwiftUI
import MapKit
import ScoutKit

/// A collaborator's access level on a shared project. Maps to CloudKit's CKShare permissions
/// (.readWrite / .readOnly) once iCloud sharing is wired up (docs/collaboration-plan.md).
enum ShareRole: Hashable {
    case editor   // can view and make changes
    case viewer   // read-only
}

/// The single source of truth for the app's selection, shared by every view that shows it:
/// the sidebar rows, the photo-grid cells, and the map pins. Selecting in any one view writes
/// here; the others observe the same store and update automatically.
///
/// Keyed by UUID (each `PinVM`/`ListVM` has a stable `uuid`, and
/// `ScoutLocation.id` is that same uuid) — the common identifier across all three views.
/// The set normally holds selected PHOTO uuids; the sidebar may also include folder/list
/// uuids (folders aren't pins, so the grid and map simply ignore ids they don't render).
///
/// A reference type so it can be owned high up via plain @State and passed down without
/// re-rendering the owner on every change. Only leaf rows/cells `@ObservedObject` it (and the
/// map subscribes via Combine), so selecting thousands of items repaints just what's visible.
///
/// ⚠️ INVARIANT — DO NOT BREAK (this caused a long, painful multi-select bug):
/// `ids` is mutated ONLY by deliberate selection actions: grid `selectItem`, sidebar
/// `handleTap`/`moveSelection`, map option-click, and explicit clears (delete/move/dismiss).
/// It must NEVER be overwritten as a side effect of a *highlight* change. The single-item
/// highlight (`highlightedPinID`) and the map popover (`selectedLocation`) are SEPARATE concepts
/// from this multi-selection set. A highlight may scroll a view or open a popover, but writing
/// `selection.ids = [oneItem]` in response to a highlight change wipes an in-progress
/// multi-select on every click. (That's exactly what the sidebar's `onChange(of:scrollToPinUUID)`
/// used to do — it now only scrolls.) If you find a `selection.ids = [...]` reacting to a
/// highlight/scroll/onChange rather than to a user's click, that's the bug — remove it.
final class SelectionStore: ObservableObject {
    @Published var ids: Set<UUID> = []
    /// Anchor for shift-range selection (last single-clicked id).
    var anchor: UUID? = nil
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}

// MARK: - Shared pin context menu (sidebar, photo grid, and map all use this)

/// Where the right-click happened — selects which "Reveal …" options appear.
/// the view (the @State value — the reference — is unchanged).
final class PinDisplayCache {
    private var locs: [String: (sig: Int, loc: ScoutLocation)] = [:]
    private var proximity: [String: (sig: Int, result: [PinVM])] = [:]

    @MainActor func location(for pin: PinVM) -> ScoutLocation {
        let sig = Self.pinSignature(pin)
        if let c = locs[pin.id], c.sig == sig { return c.loc }
        let loc = pin.asScoutLocation()
        locs[pin.id] = (sig, loc)
        return loc
    }

    /// Returns the proximity-ordered pins for `key`, recomputing via `compute` only when the
    /// input set/order signature changes. `pins` must already be filtered + sorted by caller.
    @MainActor func proximityOrdered(_ key: String, pins: [PinVM],
                          compute: ([PinVM]) -> [PinVM]) -> [PinVM] {
        var hasher = Hasher()
        for p in pins { hasher.combine(p.id); hasher.combine(p.sortOrder) }
        let sig = hasher.finalize()
        if let c = proximity[key], c.sig == sig { return c.result }
        let result = compute(pins)
        proximity[key] = (sig, result)
        return result
    }

    /// Clears everything — used when on-disk file availability changes (e.g. relink), which
    /// affects `fullResImages` but isn't part of the per-pin signature.
    func invalidateAll() { locs.removeAll(); proximity.removeAll() }

    @MainActor private static func pinSignature(_ pin: PinVM) -> Int {
        var h = Hasher()
        h.combine(pin.rotationQuarterTurns)
        h.combine(pin.name)
        h.combine(pin.latitude); h.combine(pin.longitude); h.combine(pin.hasGPS)
        h.combine(pin.photoFiles); h.combine(pin.thumbnailFiles)
        h.combine(pin.originalFilename)
        h.combine(pin.statusRaw)
        h.combine(pin.isFlagged)
        return h.finalize()
    }
}


struct ContentView: View {
    @StateObject var locationManager = LocationManager.shared

    // Persisted camera region — 4 doubles in UserDefaults (not sensitive)
    @AppStorage("map.lat")         var savedLat:      Double = .nan
    @AppStorage("map.lng")         var savedLng:      Double = .nan
    @AppStorage("map.latDelta")    var savedLatDelta: Double = .nan
    @AppStorage("map.lngDelta")    var savedLngDelta: Double = .nan
    @AppStorage("map.scrollToZoom") var scrollToZoom: Bool = false
    @AppStorage("aiScout.constrainToMap") var aiConstrainToMap: Bool = true

    @StateObject var mapController = ScoutMapController()
    @StateObject var searchArea = SearchAreaManager.shared
    @StateObject var photoViewer = PhotoViewerState.shared

    @AppStorage("rightPanel.tab") var rightPanelTab: RightPanelTab = .ai
    @AppStorage("map.cyclingProvider") var cyclingProviderRaw: String = ""
    @AppStorage("map.style") var mapStyle: MapStyle = .explore
    @AppStorage("wikimedia.limit") var wikiLimit: Double = 50
    @AppStorage("flickr.limit")       var flickrLimit:       Double = 50
    @AppStorage("foursquare.limit")   var foursquareLimit:   Double = 50
    @State var showLayersPopover = false
    @AppStorage("map.showPhotoAnnotations") var showPhotoAnnotations = false
    @AppStorage("map.pinSize") var pinSize: Double = 1.0
    @State var regionQuery = ""
    @State var isRegionSearching = false
    @State var savedRegions: [SavedRegion] = []

    // Boundary overlay state
    @AppStorage("boundary.showPrefectures") var showPrefectures = false
    @AppStorage("boundary.showMunicipalities") var showMunicipalities = false
    @AppStorage("boundary.showNames") var showBoundaryNames = true
    @AppStorage("boundary.opacity") var boundaryOpacity: Double = 0.2
    @State var showBoundaryPopover = false
    @State var prefectureBoundaries: [JapanBoundaryService.BoundaryData] = []
    @State var municipalityBoundaries: [JapanBoundaryService.BoundaryData] = []
    @State var isLoadingPrefectures = false
    @State var isLoadingMunicipalities = false
    @State var boundaryError: String? = nil
    @State var cachedBoundaryPolygons: [BoundaryPolygon] = []
    @AppStorage("boundary.nameLanguage") var boundaryNameLanguage: BoundaryNameLanguage = .japanese

    var cyclingProvider: CyclingTileProvider? {
        get { CyclingTileProvider(rawValue: cyclingProviderRaw) }
        set { cyclingProviderRaw = newValue?.rawValue ?? "" }
    }

    /// The store-backed VM graph (PowerSync) — replaces the Core Data @FetchRequests. The
    /// same-named computed properties below keep the rest of the view body unchanged.
    @ObservedObject var mac = MacStore.shared
    var allLists: [ListVM] { mac.lists }
    // Pins not attached to any list or project — always shown on the map.
    var unfiledPins: [PinVM] { mac.pins.filter { $0.listId == nil && $0.owningProjectId == nil } }
    // All pins, for the one-time offline-photo backfill.
    var allPins: [PinVM] { mac.pins }
    var allProjects: [ProjectVM] { mac.projects }
    // All script highlights — drives Script-view tinting reactively, so removing a scene link
    // (or its list) repaints the script immediately instead of leaving a "ghost" highlight.
    var allScriptHighlights: [HighlightVM] { mac.highlights }

    @State var searchText = ""
    @State var isSearching = false
    @State var isAISearching = false
    @State var locations: [ScoutLocation] = []
    @State var selectedLocation: ScoutLocation?
    @State var searchError: String?
    @State var backupStatusMessage: String? = nil
    @State var backupProgress: Double? = nil
    @State var isBackupBusy = false
    @State var didInitialCenter = false
    @State var chatMessages: [ChatMessage] = []
    @State var viewMode: ViewMode = .map
    @AppStorage("ui.showProjectsPanel") var showProjectsPanel = true
    @AppStorage("ui.showRightPanel") var showRightPanel = true
    // Left sidebar width — user-draggable, persisted. Min/max are tweakable in the Debug panel.
    @AppStorage("ui.sidebarWidth") var sidebarWidth: Double = 280
    // Live width while a resize drag is in progress. Plain @State so dragging never thrashes
    // UserDefaults (an AppStorage write per tick serializes + persists + KVO-notifies). The
    // final value is committed to `sidebarWidth` once, on drag end.
    @State var liveSidebarWidth: Double? = nil
    @AppStorage("debug.sidebarMinWidth") var sidebarMinWidth: Double = 200
    @AppStorage("debug.sidebarMaxWidth") var sidebarMaxWidth: Double = 480
    @State var activeListIDs: Set<String> = []
    // Projects whose uncategorized (loose) photos are hidden from map + grid.
    // Empty = all visible (default). Toggled by the sidebar "Uncategorized" eye.
    @State var hiddenUncategorizedProjectIDs: Set<String> = []
    @AppStorage("nav.activeListUUIDs") var activeListUUIDs: String = ""
    @AppStorage("nav.openProjectUUID") var openProjectUUID: String = ""
    // Flipped by the debug "Clear Old Lists" button to drive the purge inside ProjectsPanel.
    @State var purgeTrigger = false
    // Pin highlighted via list-view tap — used to scroll+highlight in the photo grid.
    @State var highlightedPinID: UUID? = nil
    /// Set when switching to the grid so it scrolls to the photo nearest the map's location.
    @State var gridScrollTargetID: UUID? = nil
    // Cached pin arrays so asScoutLocation() isn't called on every ContentView body render.
    // Rebuilt only when the underlying SwiftData queries or activeListIDs actually change.
    @State var cachedProjectPins: [(ScoutLocation, String)] = []
    @State var cachedGridSections: [PhotoGridView.Section] = []
    /// UUIDs to move when the move sheet is triggered from the grid or M key outside sidebar.
    @State var externalMoveUUIDs: [UUID] = []
    /// THE single source of truth for what's selected. The sidebar, the photo grid, and the
    /// map pins all read and write this one store, so a selection made in any view is reflected
    /// in the other two automatically. Owned here via plain @State (NOT @StateObject) so
    /// mutating it never re-runs ContentView's body — only the leaf rows/cells that
    /// @ObservedObject it, and the map's Combine subscription, react. See SelectionStore.
    @State var selection = SelectionStore()
    /// Set by the "Reveal in List" command (grid/map right-click) to ask the sidebar to expand
    /// the pin's list/folder chain and scroll to its row. A fresh value each time so re-revealing
    /// the same pin still fires the sidebar's onChange.
    @State var revealInListUUID: UUID? = nil
    /// The script currently shown in Script mode (selected from the sidebar). Resolved against
    /// the open project's scripts; falls back to the first script.
    @State var activeScriptUUID: UUID? = nil
    /// The script text range awaiting a list assignment (set when `m` is pressed in Script mode).
    @State var pendingScriptRange: NSRange? = nil
    @State var showScriptListPicker = false
    /// New-list-and-assign flow from the Script view's right-click menu.
    @State var showScriptNewListSheet = false
    @State var scriptNewListName = ""
    /// When set, the Script view scrolls to & selects this range (jump-to-scene from a list).
    @State var scriptScrollTarget: NSRange? = nil
    /// Set when a script highlight is clicked — reveals & selects its linked list in the sidebar.
    @State var revealListUUID: UUID? = nil
    /// Collaboration (project sharing) popover — UI shell; real iCloud sharing is wired later
    /// per docs/collaboration-plan.md.
    @State var showCollaborationPopover = false
    @State var sharingProject: ProjectVM? = nil
    /// Global "show flagged only" filter — shared with the sidebar via AppStorage; applies to
    /// the map and photo grid through rebuildPinCaches.
    @AppStorage("filter.flaggedOnly") var flaggedOnly = false
    @State var addPersonEmail = ""
    @State var addPersonRole: ShareRole = .editor
    /// Whole-page zoom for the Script view (Cmd +/-), persisted across launches. Starts a bit
    /// zoomed in since the page is small to read at 1.0.
    @AppStorage("scriptZoom") var scriptZoom: Double = 1.3

    var openProject: ProjectVM? {
        allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })
    }

    var activeScript: ScriptVM? {
        let scripts = openProject?.scripts ?? []
        if let id = activeScriptUUID, let s = scripts.first(where: { $0.uuid == id }) { return s }
        return scripts.sorted { $0.sortOrder < $1.sortOrder }.first
    }

    /// Highlight ranges for the active script, sourced from the reactive `@Query` so they update
    /// the instant a scene link (or its list) is removed. Highlights with no list are skipped.
    var activeScriptHighlights: [(NSRange, ScriptHighlightColor)] {
        #if os(macOS)
        guard let script = activeScript else { return [] }
        return allScriptHighlights
            // Stable order (the @Query is unsorted) so the Script view doesn't rebuild — and reset
            // the scroll — on every re-render when there are multiple highlights.
            .filter { $0.script?.uuid == script.uuid }
            .sorted { $0.rangeStart < $1.rangeStart }
            .compactMap { h in
                // Skip links whose list is gone or in the Trash (soft-deleted) — those were the
                // lingering "ghost" highlights.
                guard let list = h.list, list.deletedAt == nil,
                      let color = NSColor(hexString: list.colorHex) else { return nil }
                return (NSRange(location: h.rangeStart, length: h.rangeLength), color)
            }
        #else
        return []
        #endif
    }
    /// Shows MoveToListSheet from ContentView when sidebar is hidden.
    @State var showExternalMoveSheet = false
    /// Duplicate pins found by the debug "Find Duplicates" scan, awaiting confirmation to trash.
    @State var pendingDuplicateRemoval: [PinVM] = []
    @State var pendingDuplicateClusters = 0
    @State var showDuplicateConfirm = false
    /// Signature-keyed cache that makes visibility toggles instant at thousands of pins.
    @State var displayCache = PinDisplayCache()
    /// Incremented whenever the map's project-pin cache is rebuilt, so ScoutMapView can skip
    /// re-diffing thousands of pins on re-renders where the pins didn't change.
    @State var pinCacheVersion = 0

    var hasSavedRegion: Bool {
        !savedLat.isNaN && !savedLng.isNaN
    }

    /// Lists scoped to the currently open project, or all lists if no project is open.
    var openProjectLists: [ListVM] {
        guard !openProjectUUID.isEmpty,
              let project = allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })
        else { return [] }
        // Match the sidebar order (panelOrder, then createdAt) so the Save / map
        // callout menus list lists in the same order the user arranged them.
        // Trashed lists are excluded so you can't save into a list that's in the Trash.
        return project.lists.filter { $0.deletedAt == nil }.sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    var initialRegion: MKCoordinateRegion? {
        guard hasSavedRegion else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: savedLat, longitude: savedLng),
            span: MKCoordinateSpan(latitudeDelta: savedLatDelta, longitudeDelta: savedLngDelta)
        )
    }

    var body: some View {
        // DECOUPLE window size from content size. A SwiftUI WindowGroup's default resizability
        // tracks the content's measured min size, so a transient change during a photo-grid
        // refresh (after an "m" move, etc.) was nudging the window. A root GeometryReader breaks
        // that link: it reports only ITS OWN flexible size to the window and hands the content a
        // concrete size — so nothing the content does internally can ever change the window's
        // dimensions. The min floor is constant; macOS persists/restores the user's chosen size.
        GeometryReader { geo in
            rootLayoutWithObservers
                .frame(width: geo.size.width, height: geo.size.height)
                // Centered share panel (a SwiftUI .sheet can't center on macOS — it drops from the
                // top — so present it as a dimmed, window-centered overlay instead).
                .overlay {
                    if let project = sharingProject {
                        ZStack(alignment: .topTrailing) {
                            Color.black.opacity(0.35)
                                .ignoresSafeArea()
                                .onTapGesture { sharingProject = nil }
                            // Anchor near the top-right, roughly under the share button.
                            ProjectShareSheet(project: project, onDismiss: { sharingProject = nil })
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                                .shadow(radius: 24)
                                .padding(.top, 54)
                                .padding(.trailing, 12)
                        }
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: sharingProject != nil)
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        #if os(macOS)
        .task { await photoUploadCheckLoop() }
        #endif
    }

    #if os(macOS)
    /// Periodically make sure every local photo has been pushed to Storage, so other devices can
    /// download them. Runs shortly after launch (once the store has pins) and every few minutes
    /// after. The ledger makes repeat passes cheap — only new/missing files are sent — and the sync
    /// bar shows progress while an upload is actually in flight.
    func photoUploadCheckLoop() async {
        while !Task.isCancelled {
            if !mac.pins.isEmpty && !PhotoImportActivity.isImporting {
                // Thumbnails for every pin first (what the grid needs), then full-res.
                var thumbs: [(projectId: String, tier: PhotoStorageService.Tier, filename: String)] = []
                var fulls: [(projectId: String, tier: PhotoStorageService.Tier, filename: String)] = []
                for pin in mac.pins where pin.deletedAt == nil {
                    guard let pid = pin.owningProjectId ?? pin.list?.projectId else { continue }
                    for f in pin.thumbnailFiles { thumbs.append((pid, .thumbnail, f)) }
                    for f in pin.photoFiles { fulls.append((pid, .full, f)) }
                }
                dlog("auto-upload check: \(mac.pins.count) pins → \(thumbs.count) thumbs + \(fulls.count) full files on disk", tag: "Photos")
                await PhotoStorageService.shared.uploadLocalPhotos(thumbs + fulls)
            }
            try? await Task.sleep(for: .seconds(300))
        }
    }
    #endif

    @ViewBuilder var rootLayoutWithObservers: some View {
        rootLayoutWithCacheObservers
            .confirmationDialog("Find & Delete Duplicates",
                                isPresented: $showDuplicateConfirm,
                                titleVisibility: .visible) {
                Button("Move \(pendingDuplicateRemoval.count) to Trash", role: .destructive) {
                    confirmRemoveDuplicates()
                }
                Button("Cancel", role: .cancel) {
                    pendingDuplicateRemoval = []
                    pendingDuplicateClusters = 0
                }
            } message: {
                Text("Found \(pendingDuplicateRemoval.count) duplicate photo\(pendingDuplicateRemoval.count == 1 ? "" : "s") across \(pendingDuplicateClusters) group\(pendingDuplicateClusters == 1 ? "" : "s"). The original (large) files are kept; the compressed copies move to the Trash (recoverable for 30 days).")
            }
    }

    @ViewBuilder var rootLayoutWithCacheObservers: some View {
        let pinCount = allPins.count, unfiledCount = unfiledPins.count
        let listCount = allLists.count, projectCount = allProjects.count
        rootLayoutWithModeObservers
            .onChange(of: pinCount)              { rebuildPinCaches() }
            .onChange(of: unfiledCount)          { rebuildPinCaches() }
            .onChange(of: listCount)             { rebuildPinCaches() }
            .onChange(of: projectCount)          { rebuildPinCaches() }
            .onChange(of: pinListAssignmentHash) { rebuildPinCaches() }
            .onChange(of: flaggedOnly)           { rebuildPinCaches() }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .scoutExportBackup))    { _ in Task { await handleExport() } }
            .onReceive(NotificationCenter.default.publisher(for: .scoutImportBackup))    { _ in Task { await handleImport() } }
            .onReceive(NotificationCenter.default.publisher(for: .scoutRelinkOriginals)) { _ in Task { await handleRelink() } }
            #endif
    }

    @ViewBuilder var rootLayoutWithModeObservers: some View {
        rootLayoutWithSelectionObservers
            .onChange(of: viewMode) { _, newMode in
                if newMode == .photos && photoViewer.restoreOnPhotoMode {
                    photoViewer.restoreOnPhotoMode = false
                    photoViewer.isVisible = true
                }
                if newMode == .map {
                    highlightedPinID = nil
                    // Reset so a later switch to .photos re-triggers the scroll even if it
                    // resolves to the same nearest photo as before.
                    gridScrollTargetID = nil
                }
                if newMode == .photos {
                    selectedLocation = nil
                    mapController.dismissPopover()
                    // Scroll the grid to the photo in/nearest the map's zoomed-in area.
                    if let id = gridLocationNearestMapCenter() {
                        gridScrollTargetID = id
                        highlightedPinID = id
                    }
                }
            }
            .onChange(of: photoViewer.isVisible) { _, visible in
                // The map popover is a native NSPopover that floats above the entire view
                // hierarchy. Always close it when the carousel opens, regardless of viewMode.
                if visible { mapController.dismissPopover() }
            }
    }

    @ViewBuilder var rootLayoutWithSelectionObservers: some View {
        rootLayoutWithSetup
            .onChange(of: selectedLocation) { _, loc in
                guard viewMode == .map, let loc else { return }
                highlightedPinID = loc.id
            }
            .onChange(of: rightPanelTab) { _, _ in
                locations = []
                selectedLocation = nil
            }
    }

    @ViewBuilder var rootLayoutWithSetup: some View {
        rootLayout
            .onAppear { setupOnAppear() }
            .onChange(of: locationManager.currentLocation?.latitude) { _, _ in centerOnUserIfNeeded() }
            .onChange(of: activeListIDs) { _, ids in
                let uuids = allLists.filter { ids.contains($0.id) }.map(\.uuid.uuidString)
                activeListUUIDs = uuids.joined(separator: ",")
                rebuildPinCaches()
            }
            .onChange(of: hiddenUncategorizedProjectIDs) { _, _ in rebuildPinCaches() }
            // Switching projects loads that project's own saved region filters.
            .onChange(of: openProjectUUID) { _, _ in loadSavedRegions() }
            // Persist whenever a region is added, toggled, or removed.
            .onChange(of: savedRegions) { _, _ in persistSavedRegions() }
    }

    /// Sidebar width clamped to the current debug min/max, so changing the limits never
    /// leaves the panel stuck outside the allowed range.
    var clampedSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, sidebarMinWidth), sidebarMaxWidth))
    }

    @ViewBuilder var rootLayout: some View {
        HStack(spacing: 0) {
            if showProjectsPanel {
                ProjectsPanel(
                    selection: selection,
                    activeListIDs: $activeListIDs,
                    hiddenUncategorizedProjectIDs: $hiddenUncategorizedProjectIDs,
                    purgeTrigger: purgeTrigger,
                    onFitToList: { pins in
                        let coords = pins.map(\.coordinate)
                        guard !coords.isEmpty else { return }
                        mapController.fit(coords, animated: true)
                    },
                    onSelectPin: selectPin,
                    onZoomToPin: zoomToPin,
                    onClearPin: { selectedLocation = nil },
                    onRevealPins: { pins in
                        let gps = pins.filter { $0.hasGPS }
                        guard !gps.isEmpty else { return }
                        withAnimation(.spring(duration: 0.3)) { viewMode = .map }
                        let coords = gps.map(\.coordinate)
                        let ids = gps.map(\.uuid)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            mapController.revealPins(coords: coords, order: ids, delay: 0.9)
                        }
                    },
                    onOpenCarousel: openInCarousel,
                    onOpenScript: { script in
                        activeScriptUUID = script.uuid
                        withAnimation(.spring(duration: 0.3)) { viewMode = .script }
                    },
                    onOpenScriptHighlight: { highlight in openScriptHighlight(highlight) },
                    onSelectListForScript: { list in scrollScriptToList(list) },
                    onRevealInGrid: { id in revealInGrid(id) },
                    onRevealOnMap: { id in revealOnMap(id) },
                    scrollToPinUUID: highlightedPinID,
                    revealInListUUID: revealInListUUID,
                    revealListUUID: revealListUUID,
                    externalMoveUUIDs: $externalMoveUUIDs
                )
                .frame(width: liveSidebarWidth.map { CGFloat(min(max($0, sidebarMinWidth), sidebarMaxWidth)) } ?? clampedSidebarWidth)
                .transition(.move(edge: .leading))
                SidebarResizeHandle(
                    width: liveSidebarWidth ?? sidebarWidth,
                    minWidth: sidebarMinWidth,
                    maxWidth: sidebarMaxWidth,
                    onLiveChange: { liveSidebarWidth = $0 },
                    onCommit: { sidebarWidth = $0; liveSidebarWidth = nil }
                )
            }
            centerPanel
                // Photo upload progress (the periodic "are all photos on the server?" check). Drops
                // below the top map toolbar (matches the 58pt clearance used elsewhere).
                .overlay(alignment: .top) { PhotoSyncBar().padding(.top, 58) }
            if showRightPanel {
                Divider()
                scoutPanel
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.spring(duration: 0.3), value: showProjectsPanel)
        .animation(.spring(duration: 0.3), value: showRightPanel)
        .ignoresSafeArea()
        .background {
            Button("", action: handleEscape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    /// Escape:
    /// - carousel opened from map popover → close carousel, stay on map, reopen popover
    /// - carousel opened from photo grid → close carousel, go back to photo grid
    /// - on map → go to photo grid
    /// - on photo grid → go to map
    func handleEscape() {
        if photoViewer.isVisible {
            let fromMap = photoViewer.openedFromMap
            photoViewer.openedFromMap = false
            photoViewer.dismiss()
            if fromMap {
                // Return to map — stay in .map mode and reopen the pin popover
                DispatchQueue.main.async { mapController.forceReopenPopover() }
            } else {
                withAnimation(.spring(duration: 0.3)) { viewMode = .photos }
            }
            return
        }
        withAnimation(.spring(duration: 0.3)) {
            viewMode = (viewMode == .map) ? .photos : .map
        }
    }

    func setupOnAppear() {
        #if os(macOS)
        // Start snapshotting modifier keys at mouse-down so option/shift multi-select works
        // reliably regardless of when SwiftUI's (deferred) tap handlers actually fire.
        ClickModifiers.shared.install()
        #endif
        repairDuplicateUUIDs()
        rebuildPinCaches()
        loadSavedRegions()   // restore this project's region filters
        // Always launch with the left projects panel open and the right search panel closed,
        // regardless of how they were left last session.
        showProjectsPanel = true
        showRightPanel = false
        locations = []
        locationManager.requestIfNeeded()
        centerOnUserIfNeeded()
        backfillPhotos()
        backfillAspectRatios()
        if !activeListUUIDs.isEmpty {
            let uuids = Set(activeListUUIDs.split(separator: ",").map(String.init))
            activeListIDs = Set(allLists.filter { uuids.contains($0.uuid.uuidString) }
                                        .map(\.id))
        }
        photoViewer.onViewOnMap = { [self] loc in
            withAnimation(.spring(duration: 0.3)) { viewMode = .map }
            selectedLocation = loc
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                mapController.center(on: loc.coordinate, animated: true)
            }
        }
    }

    /// Always open at the user's current location when permitted (you're out scouting).
    func centerOnUserIfNeeded() {
        guard !didInitialCenter,
              locationManager.isAuthorized,
              let loc = locationManager.currentLocation else { return }
        didInitialCenter = true
        mapController.center(on: loc, animated: false)
    }

    // MARK: - Unified right panel (AI + search sources)


    static let generalPinColor = ""   // empty = no border for uncategorized pins



}
