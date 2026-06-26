import SwiftUI
import MapKit
import SwiftData
import ScoutKit

/// The single source of truth for the app's selection, shared by every view that shows it:
/// the sidebar rows, the photo-grid cells, and the map pins. Selecting in any one view writes
/// here; the others observe the same store and update automatically.
///
/// Keyed by UUID (each `PinnedLocationData`/`LocationListData` has a stable `uuid`, and
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
enum PinMenuOrigin { case sidebar, grid, map }

/// The actions a pin's right-click menu can perform, pre-bound to a specific pin. A nil closure
/// omits that item. Each surface builds this; the ORDER, titles, and which items show is defined
/// once in `pinMenuEntries`, then rendered as SwiftUI buttons (sidebar/grid) or an NSMenu (map).
struct PinMenuActions {
    var isFlagged: Bool
    var toggleFlag: () -> Void
    var revealInFinder: (() -> Void)?
    var revealInList: (() -> Void)?
    var revealInGrid: (() -> Void)?
    var revealOnMap: (() -> Void)?
    var delete: () -> Void
}

struct PinMenuEntry: Identifiable {
    let id = UUID()
    var separatorBefore = false
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void
}

/// THE single source of menu structure/order/titles for a pin. Surface-specific reveal options
/// are chosen by `origin`; everything else (Flag, Reveal in Finder, Delete) is identical.
func pinMenuEntries(_ origin: PinMenuOrigin, _ a: PinMenuActions) -> [PinMenuEntry] {
    var e: [PinMenuEntry] = []
    e.append(.init(title: a.isFlagged ? "Unflag" : "Flag as Filming Location",
                   systemImage: a.isFlagged ? "flag.slash" : "flag", action: a.toggleFlag))
    if let f = a.revealInFinder {
        e.append(.init(title: "Reveal in Finder", systemImage: "folder", action: f))
    }
    // Surface-specific "Reveal …" options, right below Reveal in Finder.
    switch origin {
    case .sidebar:
        if let g = a.revealInGrid { e.append(.init(title: "Reveal in Photo Grid", systemImage: "square.grid.2x2", action: g)) }
        if let m = a.revealOnMap  { e.append(.init(title: "Reveal on Map", systemImage: "map", action: m)) }
    case .grid:
        if let l = a.revealInList { e.append(.init(title: "Reveal in List", systemImage: "list.bullet", action: l)) }
        if let m = a.revealOnMap  { e.append(.init(title: "Reveal on Map", systemImage: "map", action: m)) }
    case .map:
        if let g = a.revealInGrid { e.append(.init(title: "Reveal in Photo Grid", systemImage: "square.grid.2x2", action: g)) }
        if let l = a.revealInList { e.append(.init(title: "Reveal in List", systemImage: "list.bullet", action: l)) }
    }
    e.append(.init(separatorBefore: true, title: "Delete", systemImage: "trash", destructive: true, action: a.delete))
    return e
}

/// SwiftUI renderer (sidebar + photo grid). The map renders the same entries as an NSMenu.
@ViewBuilder
func pinContextMenuItems(_ origin: PinMenuOrigin, _ actions: PinMenuActions) -> some View {
    ForEach(pinMenuEntries(origin, actions)) { entry in
        if entry.separatorBefore { Divider() }
        Button(role: entry.destructive ? .destructive : nil, action: entry.action) {
            Label(entry.title, systemImage: entry.systemImage)
        }
    }
}

/// Caches the two expensive pieces of `rebuildPinCaches` so a visibility toggle (which
/// changes neither a pin's data nor a list's membership) reuses results instead of
/// recomputing them for thousands of pins on the main thread:
///   • `asScoutLocation()` — does a per-pin disk stat (`isReadableFile`) via fullResImages.
///   • `proximityOrdered()` — an O(n²) nearest-neighbour walk per list section.
/// Both are keyed by a cheap content signature, so any real change (rotation, new photos,
/// moved/added/removed pins, reorder) self-invalidates while a pure show/hide hits the cache.
/// Held by the view via plain @State: mutating its internal dictionaries does NOT re-render
/// the view (the @State value — the reference — is unchanged).
final class PinDisplayCache {
    private var locs: [PersistentIdentifier: (sig: Int, loc: ScoutLocation)] = [:]
    private var proximity: [PersistentIdentifier: (sig: Int, result: [PinnedLocationData])] = [:]

    func location(for pin: PinnedLocationData) -> ScoutLocation {
        let sig = Self.pinSignature(pin)
        if let c = locs[pin.persistentModelID], c.sig == sig { return c.loc }
        let loc = pin.asScoutLocation()
        locs[pin.persistentModelID] = (sig, loc)
        return loc
    }

    /// Returns the proximity-ordered pins for `key`, recomputing via `compute` only when the
    /// input set/order signature changes. `pins` must already be filtered + sorted by caller.
    func proximityOrdered(_ key: PersistentIdentifier, pins: [PinnedLocationData],
                          compute: ([PinnedLocationData]) -> [PinnedLocationData]) -> [PinnedLocationData] {
        var hasher = Hasher()
        for p in pins { hasher.combine(p.persistentModelID); hasher.combine(p.sortOrder) }
        let sig = hasher.finalize()
        if let c = proximity[key], c.sig == sig { return c.result }
        let result = compute(pins)
        proximity[key] = (sig, result)
        return result
    }

    /// Clears everything — used when on-disk file availability changes (e.g. relink), which
    /// affects `fullResImages` but isn't part of the per-pin signature.
    func invalidateAll() { locs.removeAll(); proximity.removeAll() }

    private static func pinSignature(_ pin: PinnedLocationData) -> Int {
        var h = Hasher()
        h.combine(pin.rotationQuarterTurns)
        h.combine(pin.name)
        h.combine(pin.latitude); h.combine(pin.longitude); h.combine(pin.hasGPS)
        h.combine(pin.photoFiles); h.combine(pin.thumbnailFiles)
        h.combine(pin.originalFilePath)
        h.combine(pin.statusRaw)
        h.combine(pin.isFlagged)
        return h.finalize()
    }
}


struct ContentView: View {
    @StateObject private var locationManager = LocationManager.shared

    // Persisted camera region — 4 doubles in UserDefaults (not sensitive)
    @AppStorage("map.lat")         private var savedLat:      Double = .nan
    @AppStorage("map.lng")         private var savedLng:      Double = .nan
    @AppStorage("map.latDelta")    private var savedLatDelta: Double = .nan
    @AppStorage("map.lngDelta")    private var savedLngDelta: Double = .nan
    @AppStorage("map.scrollToZoom") private var scrollToZoom: Bool = false
    @AppStorage("aiScout.constrainToMap") private var aiConstrainToMap: Bool = true

    @StateObject private var mapController = ScoutMapController()
    @StateObject private var searchArea = SearchAreaManager.shared
    @StateObject private var photoViewer = PhotoViewerState.shared

    @AppStorage("rightPanel.tab") private var rightPanelTab: RightPanelTab = .ai
    @AppStorage("map.cyclingProvider") private var cyclingProviderRaw: String = ""
    @AppStorage("map.style") private var mapStyle: MapStyle = .explore
    @AppStorage("wikimedia.limit") private var wikiLimit: Double = 50
    @AppStorage("flickr.limit")       private var flickrLimit:       Double = 50
    @AppStorage("foursquare.limit")   private var foursquareLimit:   Double = 50
    @State private var showLayersPopover = false
    @AppStorage("map.showPhotoAnnotations") private var showPhotoAnnotations = false
    @AppStorage("map.pinSize") private var pinSize: Double = 1.0
    @State private var regionQuery = ""
    @State private var isRegionSearching = false
    @State private var savedRegions: [SavedRegion] = []

    // Boundary overlay state
    @AppStorage("boundary.showPrefectures") private var showPrefectures = false
    @AppStorage("boundary.showMunicipalities") private var showMunicipalities = false
    @AppStorage("boundary.showNames") private var showBoundaryNames = true
    @AppStorage("boundary.opacity") private var boundaryOpacity: Double = 0.2
    @State private var showBoundaryPopover = false
    @State private var prefectureBoundaries: [JapanBoundaryService.BoundaryData] = []
    @State private var municipalityBoundaries: [JapanBoundaryService.BoundaryData] = []
    @State private var isLoadingPrefectures = false
    @State private var isLoadingMunicipalities = false
    @State private var boundaryError: String? = nil
    @State private var cachedBoundaryPolygons: [BoundaryPolygon] = []
    @AppStorage("boundary.nameLanguage") private var boundaryNameLanguage: BoundaryNameLanguage = .japanese

    private var cyclingProvider: CyclingTileProvider? {
        get { CyclingTileProvider(rawValue: cyclingProviderRaw) }
        set { cyclingProviderRaw = newValue?.rawValue ?? "" }
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.undoManager) private var undoManager
    @Query(sort: \LocationListData.createdAt) private var allLists: [LocationListData]
    // General pins not attached to any list — always shown on the map.
    // Pins not attached to any list or project — always shown on the map.
    @Query(filter: #Predicate<PinnedLocationData> { $0.list == nil && $0.owningProject == nil }, sort: \PinnedLocationData.createdAt)
    private var unfiledPins: [PinnedLocationData]
    // All pins, for the one-time offline-photo backfill.
    @Query private var allPins: [PinnedLocationData]
    @Query private var allProjects: [ProjectData]

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isAISearching = false
    @State private var locations: [ScoutLocation] = []
    @State private var selectedLocation: ScoutLocation?
    @State private var searchError: String?
    @State private var backupStatusMessage: String? = nil
    @State private var isBackupBusy = false
    @State private var didInitialCenter = false
    @State private var chatMessages: [ChatMessage] = []
    @State private var viewMode: ViewMode = .map
    @AppStorage("ui.showProjectsPanel") private var showProjectsPanel = true
    @AppStorage("ui.showRightPanel") private var showRightPanel = true
    // Left sidebar width — user-draggable, persisted. Min/max are tweakable in the Debug panel.
    @AppStorage("ui.sidebarWidth") private var sidebarWidth: Double = 280
    // Live width while a resize drag is in progress. Plain @State so dragging never thrashes
    // UserDefaults (an AppStorage write per tick serializes + persists + KVO-notifies). The
    // final value is committed to `sidebarWidth` once, on drag end.
    @State private var liveSidebarWidth: Double? = nil
    @AppStorage("debug.sidebarMinWidth") private var sidebarMinWidth: Double = 200
    @AppStorage("debug.sidebarMaxWidth") private var sidebarMaxWidth: Double = 480
    @State private var activeListIDs: Set<PersistentIdentifier> = []
    // Projects whose uncategorized (loose) photos are hidden from map + grid.
    // Empty = all visible (default). Toggled by the sidebar "Uncategorized" eye.
    @State private var hiddenUncategorizedProjectIDs: Set<PersistentIdentifier> = []
    @AppStorage("nav.activeListUUIDs") private var activeListUUIDs: String = ""
    @AppStorage("nav.openProjectUUID") private var openProjectUUID: String = ""
    // Flipped by the debug "Clear Old Lists" button to drive the purge inside ProjectsPanel.
    @State private var purgeTrigger = false
    // Pin highlighted via list-view tap — used to scroll+highlight in the photo grid.
    @State private var highlightedPinID: UUID? = nil
    /// Set when switching to the grid so it scrolls to the photo nearest the map's location.
    @State private var gridScrollTargetID: UUID? = nil
    // Cached pin arrays so asScoutLocation() isn't called on every ContentView body render.
    // Rebuilt only when the underlying SwiftData queries or activeListIDs actually change.
    @State private var cachedProjectPins: [(ScoutLocation, String)] = []
    @State private var cachedGridSections: [PhotoGridView.Section] = []
    /// UUIDs to move when the move sheet is triggered from the grid or M key outside sidebar.
    @State private var externalMoveUUIDs: [UUID] = []
    /// THE single source of truth for what's selected. The sidebar, the photo grid, and the
    /// map pins all read and write this one store, so a selection made in any view is reflected
    /// in the other two automatically. Owned here via plain @State (NOT @StateObject) so
    /// mutating it never re-runs ContentView's body — only the leaf rows/cells that
    /// @ObservedObject it, and the map's Combine subscription, react. See SelectionStore.
    @State private var selection = SelectionStore()
    /// Set by the "Reveal in List" command (grid/map right-click) to ask the sidebar to expand
    /// the pin's list/folder chain and scroll to its row. A fresh value each time so re-revealing
    /// the same pin still fires the sidebar's onChange.
    @State private var revealInListUUID: UUID? = nil
    /// The script currently shown in Script mode (selected from the sidebar). Resolved against
    /// the open project's scripts; falls back to the first script.
    @State private var activeScriptUUID: UUID? = nil
    /// The script text range awaiting a list assignment (set when `m` is pressed in Script mode).
    @State private var pendingScriptRange: NSRange? = nil
    @State private var showScriptListPicker = false
    /// When set, the Script view scrolls to & selects this range (jump-to-scene from a list).
    @State private var scriptScrollTarget: NSRange? = nil

    private var openProject: ProjectData? {
        allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })
    }

    private var activeScript: ScriptData? {
        let scripts = openProject?.scripts ?? []
        if let id = activeScriptUUID, let s = scripts.first(where: { $0.uuid == id }) { return s }
        return scripts.sorted { $0.sortOrder < $1.sortOrder }.first
    }
    /// Shows MoveToListSheet from ContentView when sidebar is hidden.
    @State private var showExternalMoveSheet = false
    /// Duplicate pins found by the debug "Find Duplicates" scan, awaiting confirmation to trash.
    @State private var pendingDuplicateRemoval: [PinnedLocationData] = []
    @State private var pendingDuplicateClusters = 0
    @State private var showDuplicateConfirm = false
    /// Signature-keyed cache that makes visibility toggles instant at thousands of pins.
    @State private var displayCache = PinDisplayCache()
    /// Incremented whenever the map's project-pin cache is rebuilt, so ScoutMapView can skip
    /// re-diffing thousands of pins on re-renders where the pins didn't change.
    @State private var pinCacheVersion = 0

    private var hasSavedRegion: Bool {
        !savedLat.isNaN && !savedLng.isNaN
    }

    /// Lists scoped to the currently open project, or all lists if no project is open.
    private var openProjectLists: [LocationListData] {
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

    private var initialRegion: MKCoordinateRegion? {
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
        }
        .frame(minWidth: 820, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
    }

    @ViewBuilder private var rootLayoutWithObservers: some View {
        rootLayoutWithModeObservers
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
            .onChange(of: allPins.count)         { rebuildPinCaches() }
            .onChange(of: unfiledPins.count)     { rebuildPinCaches() }
            .onChange(of: allLists.count)        { rebuildPinCaches() }
            .onChange(of: allProjects.count)     { rebuildPinCaches() }
            .onChange(of: pinListAssignmentHash) { rebuildPinCaches() }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: .scoutExportBackup))    { _ in Task { await handleExport() } }
            .onReceive(NotificationCenter.default.publisher(for: .scoutImportBackup))    { _ in Task { await handleImport() } }
            .onReceive(NotificationCenter.default.publisher(for: .scoutRelinkOriginals)) { _ in Task { await handleRelink() } }
            #endif
    }

    @ViewBuilder private var rootLayoutWithModeObservers: some View {
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

    @ViewBuilder private var rootLayoutWithSelectionObservers: some View {
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

    @ViewBuilder private var rootLayoutWithSetup: some View {
        rootLayout
            .onAppear { setupOnAppear() }
            .onChange(of: locationManager.currentLocation?.latitude) { _, _ in centerOnUserIfNeeded() }
            .onChange(of: activeListIDs) { _, ids in
                let uuids = allLists.filter { ids.contains($0.persistentModelID) }.map(\.uuid.uuidString)
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
    private var clampedSidebarWidth: CGFloat {
        CGFloat(min(max(sidebarWidth, sidebarMinWidth), sidebarMaxWidth))
    }

    @ViewBuilder private var rootLayout: some View {
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
                    onRevealInGrid: { id in revealInGrid(id) },
                    onRevealOnMap: { id in revealOnMap(id) },
                    scrollToPinUUID: highlightedPinID,
                    revealInListUUID: revealInListUUID,
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
    private func handleEscape() {
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

    private func setupOnAppear() {
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
        modelContext.undoManager = undoManager
        locationManager.requestIfNeeded()
        centerOnUserIfNeeded()
        backfillPhotos()
        backfillAspectRatios()
        if !activeListUUIDs.isEmpty {
            let uuids = Set(activeListUUIDs.split(separator: ",").map(String.init))
            activeListIDs = Set(allLists.filter { uuids.contains($0.uuid.uuidString) }
                                        .map(\.persistentModelID))
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
    private func centerOnUserIfNeeded() {
        guard !didInitialCenter,
              locationManager.isAuthorized,
              let loc = locationManager.currentLocation else { return }
        didInitialCenter = true
        mapController.center(on: loc, animated: false)
    }

    // MARK: - Unified right panel (AI + search sources)

    private var scoutPanel: some View {
        VStack(spacing: 0) {
            // Tab bar: AI | Google | Flickr | Wiki
            Picker("Panel", selection: $rightPanelTab) {
                ForEach(RightPanelTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 36)
            .padding(.bottom, 8)

            Divider()

            if rightPanelTab == .ai {
                AIChatView(
                    messages: $chatMessages,
                    isSearching: isAISearching,
                    onSend: { text, model, thinking in
                        Task { await runAISearch(query: text, model: model, extendedThinking: thinking) }
                    }
                )
            } else {
                searchContent
            }
        }
    }

    private var searchContent: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                TextField(rightPanelTab.placeholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let canBrowse = rightPanelTab == .wikimedia || rightPanelTab == .flickr || rightPanelTab == .foursquare
                        if canBrowse || !searchText.isEmpty { Task { await runSearch() } }
                    }
                Button { Task { await runSearch() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled((searchText.isEmpty && rightPanelTab != .wikimedia && rightPanelTab != .flickr && rightPanelTab != .foursquare) || isSearching)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, (rightPanelTab == .wikimedia || rightPanelTab == .flickr || rightPanelTab == .foursquare) ? 4 : 8)

            if rightPanelTab == .wikimedia || rightPanelTab == .flickr || rightPanelTab == .foursquare {
                Button {
                    Task { await runSearch() }
                } label: {
                    Label("Browse in this area", systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSearching)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                HStack(spacing: 6) {
                    Text("Max results:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: rightPanelTab == .flickr ? $flickrLimit : rightPanelTab == .foursquare ? $foursquareLimit : $wikiLimit,
                        in: 10...(rightPanelTab == .foursquare ? 50 : 500), step: 10
                    )
                    Text("\(Int(rightPanelTab == .flickr ? flickrLimit : rightPanelTab == .foursquare ? foursquareLimit : wikiLimit))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            Divider()

            if !locations.isEmpty {
                HStack {
                    Text("\(locations.count) results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        clearSearchResults()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }

            List(locations, selection: $selectedLocation) { location in
                LocationRow(location: location)
                    .draggable(location)
                    .tag(location)
                    .contextMenu {
                        let projectLists = openProjectLists
                        if !projectLists.isEmpty {
                            Menu {
                                ForEach(projectLists) { list in
                                    Button { saveToList(location, list) } label: {
                                        Label(list.name, systemImage: "mappin.circle")
                                    }
                                }
                            } label: {
                                Label("Save to List", systemImage: "folder.badge.plus")
                            }
                        }
                    }
            }
            .overlay {
                if locations.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: rightPanelTab.emptyIcon,
                        description: Text(rightPanelTab.emptyHint)
                    )
                }
            }
        }
    }

    // MARK: - Center panel (map or photo grid)

    private var centerPanel: some View {
        // Both views stay in the hierarchy at all times:
        // - Map: never torn down so MapKit/CVDisplayLink stay alive
        // - PhotoGrid: never torn down so scroll position survives "Show on Map" round-trips
        ZStack {
            scoutMap
                .zIndex(0)
            PhotoGridView(
                selection: selection,
                locations: locations,
                pinnedSections: cachedGridSections,
                dataVersion: pinCacheVersion,
                highlightedLocationID: highlightedPinID,
                scrollTargetID: gridScrollTargetID,
                onClearSearchResults: clearSearchResults,
                onSelectLocation: { id in highlightedPinID = id },
                onDoubleSelectLocation: { id in
                    if let pin = allPins.first(where: { $0.uuid == id }) {
                        openInCarousel(pin)
                    }
                },
                onMoveToList: { uuids in externalMoveUUIDs = uuids },
                onToggleFlag: { uuids in toggleFlag(uuids) },
                onRevealInList: { id in revealInList(id) },
                onRevealOnMap: { id in revealOnMap(id) },
                onDelete: { uuids in trashPins(uuids) },
                onRotate: { uuids in rotatePins(uuids) },
                originalFilePath: { id in allPins.first(where: { $0.uuid == id })?.originalFilePath }
            )
                .ignoresSafeArea()
                .opacity(viewMode == .photos ? 1 : 0)
                .allowsHitTesting(viewMode == .photos)
                .zIndex(10)
            ScriptView(script: activeScript,
                       onAssign: { range in beginScriptAssign(range) },
                       scrollTarget: scriptScrollTarget)
                .opacity(viewMode == .script ? 1 : 0)
                .allowsHitTesting(viewMode == .script)
                .zIndex(15)
            if photoViewer.isVisible {
                PhotoViewerOverlay(availableLists: openProjectLists, onSave: savePinned,
                                   onRotate: { url in rotatePin(forImageURL: url) },
                                   onDelete: { loc in deletePinFromCarousel(loc) })
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: photoViewer.isVisible)
                    .zIndex(20)
            }
        }
        // M key: open move sheet from photo grid or map selection (sidebar handles its own M).
        .background {
            Button("") {
                let uuids: [UUID] = {
                    // The shared selection (sidebar/grid/map all write it) wins, then the
                    // highlighted grid pin, then the map popover's pin.
                    if !selection.ids.isEmpty { return Array(selection.ids) }
                    if let id = highlightedPinID { return [id] }
                    if let id = selectedLocation?.id { return [id] }
                    return []
                }()
                if !uuids.isEmpty { externalMoveUUIDs = uuids }
            }
            .keyboardShortcut("m", modifiers: [])
            // Disable while the move sheet is open (so "m" typed into its search field can't
            // re-fire this), and in Script mode (where "m" assigns the selected script range to
            // a list via the Script view's own key handler).
            .disabled(showExternalMoveSheet || viewMode == .script)
            .opacity(0)
            .allowsHitTesting(false)
        }
        // U key: reset/toggle user-location follow — same as the location button on the map.
        .background {
            Button("") { mapController.toggleTracking() }
                .keyboardShortcut("u", modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Delete key in grid/map mode: trash every selected photo. The sidebar has its own
        // delete handler for when it's focused; this covers the center panel.
        .background {
            Button("", action: deleteSelectedPhotos)
                .keyboardShortcut(.delete, modifiers: [])
                // Not while reading a script — Delete there must not trash selected photos.
                .disabled(viewMode == .script)
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Clear the shared selection once the move sheet has closed.
        // Also open the sheet here when the sidebar is hidden (ProjectsPanel is not in hierarchy).
        .onChange(of: externalMoveUUIDs) { _, ids in
            if ids.isEmpty {
                selection.ids = []
                showExternalMoveSheet = false
            } else if !showProjectsPanel {
                showExternalMoveSheet = true
            }
        }
        .sheet(isPresented: $showExternalMoveSheet, onDismiss: { externalMoveUUIDs = [] }) {
            if let project = allProjects.first(where: { $0.uuid.uuidString == openProjectUUID }) {
                MoveToListSheet(
                    project: project,
                    onMove: { list in
                        let pins = externalMoveUUIDs.compactMap { uuid in
                            allPins.first(where: { $0.uuid == uuid })
                        }
                        for pin in pins {
                            if let oldList = pin.list {
                                oldList.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
                                pin.list = nil
                            }
                            pin.owningProject?.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
                            pin.owningProject = nil
                            // Set the inverse only — SwiftData adds to list.pins automatically.
                            // Inserting manually too would duplicate the pin in list.pins.
                            pin.list = list
                        }
                        for (i, p) in list.pins.sorted(by: { $0.sortOrder < $1.sortOrder }).enumerated() { p.sortOrder = i }
                        try? modelContext.save()
                        externalMoveUUIDs = []
                        selection.ids = []
                        showExternalMoveSheet = false
                    },
                    onDismiss: { externalMoveUUIDs = []; showExternalMoveSheet = false }
                )
            }
        }
        // Script mode: pick which list a highlighted script section belongs to.
        .sheet(isPresented: $showScriptListPicker, onDismiss: { pendingScriptRange = nil }) {
            if let project = openProject {
                MoveToListSheet(
                    project: project,
                    onMove: { list in assignScriptSelection(to: list) },
                    onDismiss: { showScriptListPicker = false; pendingScriptRange = nil }
                )
            }
        }
        .overlay(alignment: .top) {
            HStack {
                panelToggleButton(
                    icon: showProjectsPanel ? "folder.fill" : "folder",
                    action: { showProjectsPanel.toggle() }
                )
                Spacer()
                viewModeToggle
                Spacer()
                HStack(spacing: 4) {
                    fitAllPinsButton
                    locationTrackingButton
                    panelToggleButton(
                        icon: "magnifyingglass",
                        circle: true,
                        action: { showRightPanel.toggle() }
                    )
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 8)
        }
    }

    private var fitAllPinsButton: some View {
        Button { frameAllProjectPins() } label: {
            Image(systemName: "viewfinder")
                .font(.subheadline.weight(.medium))
                .mapControlChrome(diameter: 32, circle: false)
        }
        .buttonStyle(.plain)
        .disabled(cachedProjectPins.isEmpty)
    }

    private var locationTrackingButton: some View {
        #if os(macOS)
        // macOS MapKit has no MKUserTrackingButton, so drive the map directly.
        let tracking = mapController.userTrackingMode == .follow
        return Button { mapController.toggleTracking() } label: {
            Image(systemName: tracking ? "location.fill" : "location")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tracking ? .blue : .primary)
                .mapControlChrome(diameter: 32, circle: false)
        }
        .buttonStyle(.plain)
        #else
        return UserTrackingButtonView(controller: mapController)
            .mapControlChrome(diameter: 32, circle: false)
        #endif
    }

    private func panelToggleButton(icon: String, circle: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .mapControlChrome(diameter: 32, circle: circle)
        }
        .buttonStyle(.plain)
    }

    private static let generalPinColor = ""   // empty = no border for uncategorized pins

    /// Changes whenever any pin's list membership, sort order, or trashed state changes,
    /// even when total counts are unchanged — used to trigger a grid/map rebuild after a
    /// drag-reorder or a soft-delete (trashing a pin doesn't change any count). Also folds in
    /// each list's parent-folder so nesting/unnesting (which changes effective visibility)
    /// rebuilds too.
    private var pinListAssignmentHash: Int {
        var h = allPins.reduce(0) { acc, pin in
            let listHash = pin.list?.persistentModelID.hashValue ?? 0
            let trashed = pin.deletedAt == nil ? 0 : 1
            return acc ^ listHash ^ pin.sortOrder ^ pin.panelOrder ^ trashed
        }
        for list in allLists {
            h ^= (list.parentList?.persistentModelID.hashValue ?? 0)
        }
        return h
    }

    /// Rotates the given pins 90° counter-clockwise (one quarter-turn) and refreshes caches.
    private func rotatePins(_ uuids: [UUID]) {
        let pins = uuids.compactMap { id in allPins.first(where: { $0.uuid == id }) }
        guard !pins.isEmpty else { return }
        for pin in pins {
            pin.rotationQuarterTurns = ((pin.rotationQuarterTurns - 1) % 4 + 4) % 4
        }
        try? modelContext.save()
        rebuildPinCaches()
    }

    /// Rotates the pin whose photo file matches `url` (used by the carousel's R key).
    private func rotatePin(forImageURL url: URL) {
        let path = url.path
        let pin = allPins.first { pin in
            if pin.originalFilePath == path { return true }
            if pin.photoFiles.contains(where: { PinPhotoStore.fileURL($0).path == path }) { return true }
            if pin.thumbnailFiles.contains(where: { PinPhotoStore.fileURL($0).path == path }) { return true }
            return false
        }
        guard let pin else { return }
        pin.rotationQuarterTurns = ((pin.rotationQuarterTurns - 1) % 4 + 4) % 4
        try? modelContext.save()
        rebuildPinCaches()
    }

    /// A list is *effectively* visible only if its own eye is on AND every ancestor folder's
    /// eye is on. A folder thus acts as a master switch: turning it off hides everything
    /// inside it on the map/grid without changing the children's own eye states.
    private func isEffectivelyActive(_ list: LocationListData) -> Bool {
        var node: LocationListData? = list
        while let n = node {
            // A trashed list (or any trashed ancestor) is never shown on the map/grid.
            if n.deletedAt != nil { return false }
            if !activeListIDs.contains(n.persistentModelID) { return false }
            node = n.parentList
        }
        return true
    }

    private func rebuildPinCaches() {
        let active = allLists.filter { isEffectivelyActive($0) }
        var mapPins: [(ScoutLocation, String)] = active.flatMap { list in
            list.pins.filter { $0.hasGPS && $0.deletedAt == nil }.map { (displayCache.location(for: $0), list.colorHex) }
        }
        for project in allProjects {
            // Skip uncategorized pins for projects whose "Uncategorized" eye is off.
            guard !hiddenUncategorizedProjectIDs.contains(project.persistentModelID) else { continue }
            for pin in project.importedPhotos where pin.hasGPS && pin.deletedAt == nil {
                mapPins.append((displayCache.location(for: pin), Self.generalPinColor))
            }
        }
        // unfiledPins (list==nil, owningProject==nil) are orphaned data from old builds.
        // They have no sidebar entry and no visibility toggle, so exclude from map.
        cachedProjectPins = mapPins

        // Sectioned grid matching sidebar order: lists inside projects, then unfiled.
        var sections: [PhotoGridView.Section] = []
        for project in allProjects.sorted(by: { $0.createdAt < $1.createdAt }) {
            // Lists inside this project in exact sidebar order: top-level lists/folders by
            // panelOrder, and each folder immediately followed by its child lists (also by
            // panelOrder). Nested lists have a panelOrder relative to their folder, so a flat
            // sort would scramble them — we must walk the hierarchy. Only visible lists shown.
            let sortedLists = orderedListsForGrid(project)
                .filter { isEffectivelyActive($0) }
            for list in sortedLists {
                let ordered = displayCache.proximityOrdered(
                    list.persistentModelID,
                    pins: list.pins.filter { $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
                ) { proximityOrdered($0) }
                let locs = flaggedFirst(ordered
                    .map { displayCache.location(for: $0) }
                    .filter { !$0.images.isEmpty })
                if !locs.isEmpty {
                    sections.append(PhotoGridView.Section(
                        title: gridSectionTitle(for: list),
                        locations: locs,
                        color: Color(hexString: list.colorHex)
                    ))
                }
            }
            // Directly-imported photos (no list).
            // Skipped entirely when this project's "Uncategorized" eye is off.
            let importedPins = hiddenUncategorizedProjectIDs.contains(project.persistentModelID)
                ? []
                : project.importedPhotos
                .filter { $0.deletedAt == nil }
                .sorted { $0.sortOrder < $1.sortOrder }
            let imported = flaggedFirst(displayCache.proximityOrdered(project.persistentModelID, pins: importedPins) { proximityOrdered($0) }
                .map { displayCache.location(for: $0) }
                .filter { !$0.images.isEmpty })
            if !imported.isEmpty {
                sections.append(PhotoGridView.Section(title: "Uncategorized", locations: imported))
            }
        }
        // Active standalone lists not belonging to any project.
        for list in active.filter({ $0.project == nil }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let ordered = displayCache.proximityOrdered(
                list.persistentModelID,
                pins: list.pins.filter { $0.deletedAt == nil }.sorted { $0.sortOrder < $1.sortOrder }
            ) { proximityOrdered($0) }
            let locs = flaggedFirst(ordered
                .map { displayCache.location(for: $0) }
                .filter { !$0.images.isEmpty })
            if !locs.isEmpty {
                sections.append(PhotoGridView.Section(
                    title: list.name,
                    locations: locs,
                    color: Color(hexString: list.colorHex)
                ))
            }
        }
        // unfiledPins (list==nil, owningProject==nil) are orphaned data from old builds.
        // They have no sidebar entry and no visibility toggle, so exclude from the grid —
        // the grid must show nothing when no list/uncategorized is visible.
        cachedGridSections = sections
        // Tell the map the project-pin set changed so it re-diffs (only) now.
        pinCacheVersion &+= 1
    }

    /// Flattens a project's lists into sidebar display order: each top-level list/folder by
    /// panelOrder, with a folder immediately followed by its child lists (also by panelOrder).
    private func orderedListsForGrid(_ project: ProjectData) -> [LocationListData] {
        var result: [LocationListData] = []
        let topLevel = project.lists
            .filter { $0.parentList == nil }
            .sorted { $0.panelOrder < $1.panelOrder }
        for list in topLevel {
            result.append(list)
            if !list.childLists.isEmpty {
                result.append(contentsOf: list.childLists.sorted { $0.panelOrder < $1.panelOrder })
            }
        }
        return result
    }

    /// The grid location closest to the map's current center — used to scroll the grid to
    /// the photos in/nearest the zoomed-in map area. Skips photos with no real coordinate.
    private func gridLocationNearestMapCenter() -> UUID? {
        guard let center = mapController.mapView?.region.center else { return nil }
        let locs = cachedGridSections.flatMap(\.locations)
            .filter { $0.coordinate.latitude != 0 || $0.coordinate.longitude != 0 }
        guard !locs.isEmpty else { return nil }
        let cosLat = cos(center.latitude * .pi / 180)
        func sqDist(_ c: CLLocationCoordinate2D) -> Double {
            let dLat = c.latitude - center.latitude
            let dLng = (c.longitude - center.longitude) * cosLat
            return dLat * dLat + dLng * dLng
        }
        return locs.min { sqDist($0.coordinate) < sqDist($1.coordinate) }?.id
    }

    /// Orders pins within a grid section so geographically close photos sit next to each
    /// other: a greedy nearest-neighbour walk starting from the north-west-most pin.
    /// GPS-less pins can't be placed spatially, so they keep their original order and go last.
    private func proximityOrdered(_ pins: [PinnedLocationData]) -> [PinnedLocationData] {
        let gps = pins.filter { $0.hasGPS }
        let noGPS = pins.filter { !$0.hasGPS }
        guard gps.count > 2 else { return gps + noGPS }

        var remaining = gps
        // Start north-west (smallest longitude, then largest latitude) for a stable anchor.
        let startIdx = remaining.indices.min {
            (remaining[$0].longitude, -remaining[$0].latitude) <
            (remaining[$1].longitude, -remaining[$1].latitude)
        }!
        var ordered = [remaining.remove(at: startIdx)]
        while !remaining.isEmpty {
            let last = ordered[ordered.count - 1]
            // Longitude degrees shrink with latitude — scale so distances aren't skewed.
            let cosLat = cos(last.latitude * .pi / 180)
            func sqDist(_ p: PinnedLocationData) -> Double {
                let dLat = p.latitude - last.latitude
                let dLng = (p.longitude - last.longitude) * cosLat
                return dLat * dLat + dLng * dLng
            }
            let nextIdx = remaining.indices.min { sqDist(remaining[$0]) < sqDist(remaining[$1]) }!
            ordered.append(remaining.remove(at: nextIdx))
        }
        return ordered + noGPS
    }

    /// Tapping a saved pin in the sidebar selects it on the map and shows its popover —
    /// exactly as if it were clicked on the map. Activates its list first so it's visible
    /// (unfiled pins are always shown), then centers on it.
    private func selectPin(_ pin: PinnedLocationData) {
        if viewMode == .photos {
            if photoViewer.isVisible { photoViewer.dismiss() }
            let id = pin.uuid
            highlightedPinID = (highlightedPinID == id) ? nil : id
            return
        }
        // Single-click in the sidebar list: just highlight the pin, no map pan.
        // Map panning only happens on double-click (zoomToPin) or clicking a map annotation.
        guard pin.hasGPS else { return }
        let location = pin.asScoutLocation()
        if selectedLocation?.id == location.id {
            selectedLocation = nil
            return
        }
        if let listID = pin.list?.persistentModelID {
            activeListIDs.insert(listID)
        }
        selectedLocation = location
    }

    /// Double-clicking a sidebar pin: switch to the map if needed, then center AND zoom
    /// into the pin (unlike single-click selectPin, which preserves the current zoom).
    private func zoomToPin(_ pin: PinnedLocationData) {
        guard pin.hasGPS else { return }
        let location = pin.asScoutLocation()
        let wasMap = (viewMode == .map)
        if !wasMap {
            withAnimation(.spring(duration: 0.3)) { viewMode = .map }
        }
        if let listID = pin.list?.persistentModelID {
            activeListIDs.insert(listID)
        }
        selectedLocation = location
        // Delay the camera move when coming from photo view so the map is laid out first.
        let zoom = { mapController.center(on: location.coordinate, meters: 800, animated: true) }
        if wasMap { zoom() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { zoom() } }
    }

    /// Opens a pin in the carousel with all pinned locations as the navigation universe,
    /// in sidebar order (matching cachedGridSections). Used for double-clicking no-GPS pins.
    private func openInCarousel(_ pin: PinnedLocationData) {
        let location = pin.asScoutLocation()
        // Build ordered universe from the grid sections (sidebar order).
        var seen = Set<UUID>()
        let allLocs = cachedGridSections.flatMap(\.locations).filter { seen.insert($0.id).inserted }
        let images = location.fullResImages.isEmpty ? location.images : location.fullResImages
        PhotoViewerState.shared.show(
            images: images,
            startingAt: 0,
            location: location,
            allLocations: allLocs
        )
    }

    private func saveToList(_ location: ScoutLocation, _ list: LocationListData) {
        // If this location is already a saved pin (id == pin.uuid), move it instead of copying.
        if let existing = allPins.first(where: { $0.uuid == location.id }) {
            movePin(existing, to: list)
            return
        }
        list.pins.forEach { $0.sortOrder += 1 }
        let pin = PinnedLocationData(from: location, sortOrder: 0)
        modelContext.insert(pin)
        pin.list = list
        cachePhotos(for: pin, from: location)
    }

    /// Save from the carousel: to a chosen list, or as a general unfiled pin (list == nil).
    private func savePinned(_ location: ScoutLocation, to list: LocationListData?) {
        // If this location is already a saved pin, move/reassign rather than duplicate.
        if let existing = allPins.first(where: { $0.uuid == location.id }) {
            if let list {
                movePin(existing, to: list)
            }
            // If list == nil the pin is already saved; nothing to do.
            return
        }
        if let list {
            list.pins.forEach { $0.sortOrder += 1 }
            let pin = PinnedLocationData(from: location, sortOrder: 0)
            modelContext.insert(pin)
            pin.list = list
            cachePhotos(for: pin, from: location)
        } else {
            let pin = PinnedLocationData(from: location)
            modelContext.insert(pin)
            cachePhotos(for: pin, from: location)
        }
    }

    /// Moves the pin backing the carousel's current location to the Trash, then refreshes
    /// caches. Soft-delete (not a hard SwiftData delete) keeps the photo recoverable and
    /// avoids the crash that hard-deleting a pin the grid/map still referenced could cause.
    /// The carousel has already dismissed itself by the time this runs.
    /// One-time data repair: reassign any DUPLICATE `uuid`s among lists/pins/projects.
    /// The whole app keys selection (and the map/grid) by `uuid` — `ScoutLocation.id` IS the
    /// pin uuid — so two rows sharing a uuid select together and can collide on the map. (Photo
    /// files are named by a separate id, so reassigning a pin's uuid never orphans its photos.)
    private func repairDuplicateUUIDs() {
        var changed = false
        var seenLists = Set<UUID>()
        for list in allLists where !seenLists.insert(list.uuid).inserted { list.uuid = UUID(); changed = true }
        var seenPins = Set<UUID>()
        for pin in allPins where !seenPins.insert(pin.uuid).inserted { pin.uuid = UUID(); changed = true }
        var seenProjects = Set<UUID>()
        for project in allProjects where !seenProjects.insert(project.uuid).inserted { project.uuid = UUID(); changed = true }
        var seenScripts = Set<UUID>()
        for script in allProjects.flatMap(\.scripts) where !seenScripts.insert(script.uuid).inserted { script.uuid = UUID(); changed = true }
        if changed { try? modelContext.save() }
    }

    /// Photo-grid section title for a list: the list name, prefixed by its folder ancestor
    /// chain ("Folder / List"), and never the project name — matching how it reads in the sidebar.
    private func gridSectionTitle(for list: LocationListData) -> String {
        var parts = [list.name]
        var node = list.parentList
        while let n = node { parts.insert(n.name, at: 0); node = n.parentList }
        return parts.joined(separator: " / ")
    }

    /// Stable partition: flagged locations first (keeping their order), then the rest.
    private func flaggedFirst(_ locs: [ScoutLocation]) -> [ScoutLocation] {
        locs.filter(\.isFlagged) + locs.filter { !$0.isFlagged }
    }

    /// Toggle the "flagged" (favorite filming location) state of the given pins. If any are
    /// unflagged, flags them all; otherwise unflags them all. Used by the grid/map.
    private func toggleFlag(_ uuids: [UUID]) {
        let pins = allPins.filter { uuids.contains($0.uuid) }
        guard !pins.isEmpty else { return }
        let shouldFlag = pins.contains { !$0.isFlagged }
        for pin in pins { pin.isFlagged = shouldFlag }
        try? modelContext.save()
        rebuildPinCaches()   // isFlagged is in the cache signature → flagged-first re-sorts
    }

    /// `m` pressed in Script mode with a selection → pick a list to assign that range to.
    private func beginScriptAssign(_ range: NSRange) {
        pendingScriptRange = range
        showScriptListPicker = true
    }

    /// Creates a ScriptHighlight linking the pending script range to the chosen list.
    private func assignScriptSelection(to list: LocationListData) {
        defer { pendingScriptRange = nil; showScriptListPicker = false }
        guard let range = pendingScriptRange, let script = activeScript else { return }
        let ns = script.rawText as NSString
        guard range.length > 0, range.location + range.length <= ns.length else { return }
        let excerpt = ns.substring(with: range)
        let beforeLen = min(40, range.location)
        let before = ns.substring(with: NSRange(location: range.location - beforeLen, length: beforeLen))
        let afterStart = range.location + range.length
        let after = ns.substring(with: NSRange(location: afterStart, length: min(40, ns.length - afterStart)))
        let heading = FountainParser.sceneHeading(in: script.rawText, before: range.location)
        let h = ScriptHighlight(rangeStart: range.location, rangeLength: range.length,
                                excerpt: excerpt, contextBefore: before, contextAfter: after,
                                sceneHeading: heading)
        modelContext.insert(h)
        h.script = script
        h.list = list
        try? modelContext.save()
    }

    /// Opens a script highlight: switch to Script mode, show its script, scroll to & select it.
    private func openScriptHighlight(_ highlight: ScriptHighlight) {
        guard let script = highlight.script else { return }
        activeScriptUUID = script.uuid
        withAnimation(.spring(duration: 0.3)) { viewMode = .script }
        // Reset first so re-opening the same highlight still triggers the scroll.
        scriptScrollTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            scriptScrollTarget = NSRange(location: highlight.rangeStart, length: highlight.rangeLength)
        }
    }

    /// "Reveal in Photo Grid": switch to the grid, scroll to the photo, and select it.
    private func revealInGrid(_ uuid: UUID) {
        if photoViewer.isVisible { photoViewer.dismiss() }
        let wasPhotos = (viewMode == .photos)
        if !wasPhotos { withAnimation(.spring(duration: 0.3)) { viewMode = .photos } }
        selection.ids = [uuid]; selection.anchor = uuid
        // Reset the scroll target first so re-revealing the same photo still fires the grid's
        // onChange. Defer past the viewMode switch (whose onChange sets its own scroll target).
        gridScrollTargetID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasPhotos ? 0.05 : 0.35)) {
            gridScrollTargetID = uuid
            highlightedPinID = uuid
        }
    }

    /// "Reveal on Map": select the pin and center/zoom the map on it (switching to map view).
    private func revealOnMap(_ uuid: UUID) {
        guard let pin = allPins.first(where: { $0.uuid == uuid }) else { return }
        selection.ids = [uuid]; selection.anchor = uuid
        zoomToPin(pin)
    }

    /// Soft-delete (trash) the given pins, updating selection and caches once.
    private func trashPins(_ uuids: [UUID]) {
        let pins = allPins.filter { uuids.contains($0.uuid) && $0.deletedAt == nil }
        guard !pins.isEmpty else { return }
        let now = Date()
        for p in pins { p.deletedAt = now }
        selection.ids.subtract(uuids)
        try? modelContext.save()
        rebuildPinCaches()
    }

    /// "Reveal in List": open the sidebar and ask it to expand the pin's list/folder chain and
    /// scroll to its row.
    private func revealInList(_ uuid: UUID) {
        let wasClosed = !showProjectsPanel
        if wasClosed {
            withAnimation(.spring(duration: 0.3)) { showProjectsPanel = true }
        }
        // Re-set so onChange fires even when revealing the same pin twice in a row. When the
        // panel was closed it must first mount and restore its nav stack, so fire after the
        // open animation; otherwise a short hop is enough.
        revealInListUUID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasClosed ? 0.4 : 0.05)) {
            revealInListUUID = uuid
        }
    }

    private func deletePinFromCarousel(_ loc: ScoutLocation) {
        guard let pin = allPins.first(where: { $0.uuid == loc.id }) else { return }
        pin.deletedAt = Date()
        try? modelContext.save()
        rebuildPinCaches()
    }

    /// Delete-key handler for the grid/map (center panel). The sidebar has its own delete
    /// shortcut, but in grid/map mode the center panel is focused, so — exactly like the "m"
    /// and "u" shortcuts — ContentView needs its own. Trashes EVERY selected photo (the whole
    /// shared multi-selection), not just the highlighted one.
    private func deleteSelectedPhotos() {
        trashPins(Array(selection.ids))
    }

    /// Debug "Find Duplicates": scans every live photo in the project for duplicates
    /// (same normalized filename, or same EXIF capture-time + GPS), then stashes the
    /// compressed copies to remove and shows a confirmation. The original large files are
    /// always kept; confirmed removals go to the Trash (recoverable, 30-day rule).
    private func findDuplicates() {
        let plan = PhotoImportService.findDuplicates(in: allPins)
        if plan.remove.isEmpty {
            DebugLogger.shared.log("No duplicates found across \(allPins.filter { $0.deletedAt == nil }.count) photos.",
                                   level: .info, tag: "Dedup")
            return
        }
        pendingDuplicateRemoval = plan.remove
        pendingDuplicateClusters = plan.clusters
        showDuplicateConfirm = true
    }

    /// Confirmed: move the previously-found duplicate copies to the Trash.
    private func confirmRemoveDuplicates() {
        let now = Date()
        for pin in pendingDuplicateRemoval { pin.deletedAt = now }
        try? modelContext.save()
        rebuildPinCaches()
        DebugLogger.shared.log("Moved \(pendingDuplicateRemoval.count) duplicate photo(s) to Trash across \(pendingDuplicateClusters) group(s); kept the original files.",
                               level: .success, tag: "Dedup")
        pendingDuplicateRemoval = []
        pendingDuplicateClusters = 0
    }

    /// Moves an existing pin out of wherever it lives and into `list`.
    private func movePin(_ pin: PinnedLocationData, to list: LocationListData) {
        // Detach from current list.
        if let oldList = pin.list {
            oldList.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
            pin.list = nil
        }
        // Detach from project top-level (importedPhotos).
        if let project = pin.owningProject {
            project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
            pin.owningProject = nil
        }
        list.pins.forEach { $0.sortOrder += 1 }
        pin.sortOrder = 0
        // Set the inverse only — SwiftData adds the pin to list.pins automatically.
        // A manual append here too would duplicate it in list.pins.
        pin.list = list
        // owningProject must stay nil for list pins — it's the inverse of importedPhotos,
        // so setting it would add the pin back to the project top-level as a duplicate.
        try? modelContext.save()
    }

    /// Download a saved pin's photos to disk and capture its source links, so it displays
    /// offsline (never refetches) and shows its Google Maps / source link in the popover.
    private func cachePhotos(for pin: PinnedLocationData, from location: ScoutLocation) {
        let placeId = pin.googlePlaceId
        let uuid = pin.uuid
        Task { @MainActor in
            let result = await PinPhotoStore.download(for: location, placeId: placeId, pinUUID: uuid)
            var changed = false
            if !result.files.isEmpty { pin.photoFiles = result.files; changed = true }
            if pin.googleMapsURLString == nil, let url = result.googleMapsURL {
                pin.googleMapsURLString = url.absoluteString; changed = true
            }
            if pin.sourceURLString == nil, let url = result.sourceURL {
                pin.sourceURLString = url.absoluteString; changed = true
            }
            if changed { try? modelContext.save() }
        }
    }

    // MARK: - Backup / restore (File menu handlers)

    #if os(macOS)
    @MainActor
    private func handleExport() async {
        guard !isBackupBusy else { return }
        guard !openProjectUUID.isEmpty,
              let project = allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })
        else { backupStatusMessage = "Open a project first to export it."; return }
        isBackupBusy = true
        backupStatusMessage = nil
        do {
            let zipURL = try await BackupService.export(project: project)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = zipURL.lastPathComponent
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let dest = panel.url else {
                try? FileManager.default.removeItem(at: zipURL)
                isBackupBusy = false
                return
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: zipURL, to: dest)
            try? FileManager.default.removeItem(at: zipURL)
            backupStatusMessage = "Exported \"\(project.name)\" to \(dest.lastPathComponent)"
        } catch {
            backupStatusMessage = "Export failed: \(error.localizedDescription)"
        }
        isBackupBusy = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { backupStatusMessage = nil }
    }

    @MainActor
    private func handleImport() async {
        guard !isBackupBusy else { return }
        isBackupBusy = true
        backupStatusMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.message = "Select a Scout backup archive"
        guard panel.runModal() == .OK, let url = panel.url else { isBackupBusy = false; return }
        do {
            let s = try await BackupService.importBackup(from: url, context: modelContext)
            backupStatusMessage = "Imported \(s.projectsAdded) projects, \(s.listsAdded) lists, \(s.pinsAdded) pins. Skipped \(s.skippedDuplicates) duplicates."
        } catch {
            backupStatusMessage = "Import failed: \(error.localizedDescription)"
        }
        isBackupBusy = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { backupStatusMessage = nil }
    }

    @MainActor
    private func handleRelink() async {
        guard !isBackupBusy else { return }
        isBackupBusy = true
        backupStatusMessage = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Select folder containing your original photo files"
        guard panel.runModal() == .OK, let url = panel.url else { isBackupBusy = false; return }
        let result = await BackupService.relinkOriginals(folder: url, context: modelContext)
        backupStatusMessage = "Relinked \(result.linked) files. \(result.notFound) not found."
        isBackupBusy = false
        // Original-file availability changed (not part of the per-pin signature) → drop caches.
        displayCache.invalidateAll()
        rebuildPinCaches()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { backupStatusMessage = nil }
    }
    #endif

    /// One-time pass over existing pins that have no offline photos yet, fetching them
    /// from their original source (stored URLs, Google place ID, or a name+area search).
    private func backfillPhotos() {
        for pin in allPins where pin.photoFiles.isEmpty {
            cachePhotos(for: pin, from: pin.asScoutLocation())
        }
    }

    /// One-time pass that fills in `aspectRatio` for pins imported before that field existed,
    /// so the photo grid can size cells without waiting for the image to load (no reflow).
    /// File headers are read off the main actor; the model is updated back on main.
    private func backfillAspectRatios() {
        // (persistentModelID, thumbnail file URL) for every pin still missing an aspect.
        let targets: [(PersistentIdentifier, URL)] = allPins.compactMap { pin in
            guard pin.aspectRatio == 0, pin.deletedAt == nil else { return nil }
            guard let file = pin.thumbnailFiles.first ?? pin.photoFiles.first else { return nil }
            return (pin.persistentModelID, PinPhotoStore.fileURL(file))
        }
        guard !targets.isEmpty else { return }
        Task {
            let results: [PersistentIdentifier: Double] = await Task.detached(priority: .utility) {
                var r: [PersistentIdentifier: Double] = [:]
                for (id, url) in targets {
                    if let a = PhotoImportService.aspectRatio(ofImageAt: url) { r[id] = a }
                }
                return r
            }.value
            guard !results.isEmpty else { return }
            for pin in allPins {
                if let a = results[pin.persistentModelID], pin.aspectRatio == 0 { pin.aspectRatio = a }
            }
            try? modelContext.save()
            // ScoutLocations cached before backfill lack the aspect → drop and rebuild.
            displayCache.invalidateAll()
            rebuildPinCaches()
        }
    }

    /// AGGRESSIVE manual cleanup (Debug "Clear Old Lists" button): deletes every project,
    /// Deletes every project (cascade removes all lists and pins) and resets nav state.
    /// Safe to call at any time — closes the panel first so no @Bindable view holds a
    /// reference to a model that's about to be deleted.
    func deleteAllData() {
        showProjectsPanel = false
        activeListIDs = []
        openProjectUUID = ""
        let all = (try? modelContext.fetch(FetchDescriptor<ProjectData>())) ?? []
        for project in all { modelContext.delete(project) }
        try? modelContext.save()
    }

    private var scoutMap: some View {
        ScoutMapView(
            selection: $selectedLocation,
            multiSelection: selection,
            locations: locations,
            projectPins: cachedProjectPins,
            projectPinsVersion: pinCacheVersion,
            scrollToZoom: scrollToZoom,
            initialRegion: initialRegion,
            controller: mapController,
            onRegionEnd: { region in
                savedLat      = region.center.latitude
                savedLng      = region.center.longitude
                savedLatDelta = region.span.latitudeDelta
                savedLngDelta = region.span.longitudeDelta
            },
            isDrawingMode: searchArea.isDrawing,
            searchPolygon: searchArea.polygon,
            onPolygonComplete: { coords in searchArea.setPolygon(coords) },
            onFrameAllPins: frameAllProjectPins,
            onPinDoubleClicked: { loc in
                // Saved pin → reuse the full grid-ordered carousel; otherwise (search
                // result) open the carousel with just this location's photos.
                if let pin = allPins.first(where: { $0.uuid == loc.id }) {
                    openInCarousel(pin)
                } else if !loc.images.isEmpty {
                    let imgs = loc.fullResImages.isEmpty ? loc.images : loc.fullResImages
                    PhotoViewerState.shared.show(images: imgs, startingAt: 0, location: loc)
                }
            },
            mapType: mapStyle.mapType,
            cyclingProvider: cyclingProvider,
            showPhotoAnnotations: showPhotoAnnotations,
            pinScale: pinSize,
            availableLists: openProjectLists,
            onSaveToList: saveToList,
            onMoveSelectionToList: { if !selection.ids.isEmpty { externalMoveUUIDs = Array(selection.ids) } },
            onRevealInList: { loc in revealInList(loc.id) },
            onRevealInGrid: { loc in revealInGrid(loc.id) },
            onToggleFlagLocation: { loc in toggleFlag([loc.id]) },
            onDeleteLocation: { loc in trashPins([loc.id]) },
            onOriginalFilePath: { loc in allPins.first(where: { $0.uuid == loc.id })?.originalFilePath },
            isSelectedPinned: allPins.contains(where: { $0.uuid == selectedLocation?.id }),
            boundaryPolygons: cachedBoundaryPolygons,
            boundaryOpacity: boundaryOpacity,
            showBoundaryNames: showBoundaryNames,
            boundaryNameLanguage: boundaryNameLanguage
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                if let msg = backupStatusMessage {
                    HStack(spacing: 6) {
                        if isBackupBusy { ProgressView().controlSize(.small) }
                        Text(msg)
                    }
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    .transition(.opacity)
                }
                if let error = searchError {
                    Text(error)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
            .padding()
            .animation(.easeInOut(duration: 0.2), value: backupStatusMessage != nil)
        }
        .overlay(alignment: .topLeading) {
            DebugPanelOverlay(onDeleteAllData: deleteAllData, onFindDuplicates: findDuplicates)
                .padding(.top, 58)
                .padding(.leading, 16)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 8) {
                layersButton
                photosButton
                boundaryButton
                lassoControls
                regionSearchOverlay
                pinSizeSlider
                if cyclingProvider == .cyclOSM {
                    cyclOSMLegend
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: cyclingProvider == .cyclOSM)
        }
    }

    private var pinSizeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            Slider(value: $pinSize, in: 0.4...2.5)
                .frame(width: 80)
                .controlSize(.mini)
            Image(systemName: "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
    }

    private var regionSearchOverlay: some View {
        let hasActive = savedRegions.contains(where: \.isActive)
        return VStack(alignment: .leading, spacing: 6) {
            // Toggle chips for saved regions
            if !savedRegions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(savedRegions.indices, id: \.self) { i in
                        RegionChip(
                            name: savedRegions[i].name,
                            isActive: savedRegions[i].isActive,
                            onToggle: {
                                savedRegions[i].isActive.toggle()
                                applyActiveRegions()
                            },
                            onDelete: {
                                savedRegions.remove(at: i)
                                applyActiveRegions()
                            }
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Search field pill
            HStack(spacing: 4) {
                Image(systemName: "globe.europe.africa")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hasActive ? .blue : .primary)

                TextField("Country, state, city…", text: $regionQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 140)
                    .onSubmit { Task { await runRegionSearch() } }

                if isRegionSearching {
                    ProgressView().controlSize(.mini)
                } else if !regionQuery.isEmpty {
                    Button {
                        regionQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { Task { await runRegionSearch() } } label: {
                        Image(systemName: "return")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(regionQuery.isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hasActive ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .animation(.easeInOut(duration: 0.2), value: savedRegions.count)
    }

    @MainActor
    private func runRegionSearch() async {
        let q = regionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isRegionSearching = true
        do {
            let result = try await NominatimService.shared.search(q)
            regionQuery = ""
            let newRegion = SavedRegion(name: result.name, polygon: result.polygon, isActive: true)
            // Deduplicate by name; if already saved just reactivate it
            if let existing = savedRegions.firstIndex(where: { $0.name == newRegion.name }) {
                savedRegions[existing].isActive = true
            } else {
                if savedRegions.count >= 3 { savedRegions.removeFirst() }
                savedRegions.append(newRegion)
            }
            applyActiveRegions()
            // Fit map to the new region's bounding box
            let b = result.bbox
            let center = CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2,
                                                longitude: (b.minLng + b.maxLng) / 2)
            let span = MKCoordinateSpan(latitudeDelta: (b.maxLat - b.minLat) * 1.15,
                                        longitudeDelta: (b.maxLng - b.minLng) * 1.15)
            mapController.setRegion(MKCoordinateRegion(center: center, span: span), animated: true)
        } catch {
            searchError = error.localizedDescription
        }
        isRegionSearching = false
    }

    // MARK: - Per-project saved-region persistence

    /// UserDefaults key for the currently open project's saved regions. Returns nil when no
    /// project is open (regions are project-scoped — different projects keep different filters).
    private var savedRegionsKey: String? {
        openProjectUUID.isEmpty ? nil : "regions.\(openProjectUUID)"
    }

    /// Loads the open project's saved regions from UserDefaults and applies the active ones.
    private func loadSavedRegions() {
        guard let key = savedRegionsKey,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedRegion].self, from: data) else {
            savedRegions = []
            applyActiveRegions()
            return
        }
        savedRegions = decoded
        applyActiveRegions()
    }

    /// Persists the current saved regions under the open project's key.
    private func persistSavedRegions() {
        guard let key = savedRegionsKey else { return }
        if savedRegions.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(savedRegions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Syncs active saved regions → searchArea polygon + boundary polygon cache.
    private func applyActiveRegions() {
        let active = savedRegions.filter(\.isActive)
        if active.isEmpty {
            searchArea.clear()
        } else {
            // Union all active region polygons into one combined point cloud for containment tests
            let combined = active.flatMap(\.polygon)
            searchArea.setPolygon(combined)
        }
        rebuildBoundaryPolygons()
    }

    private var cyclOSMLegend: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CyclOSM Key")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)

            ForEach(Self.cyclOSMLegendItems, id: \.label) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.color)
                        .frame(width: 22, height: 9)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                .padding(.bottom, 3)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private struct LegendItem {
        let color: Color
        let label: String
    }

    private static let cyclOSMLegendItems: [LegendItem] = [
        LegendItem(color: Color(red: 0.38, green: 1.00, blue: 0.59), label: "Dedicated path"),
        LegendItem(color: Color(red: 0.73, green: 1.00, blue: 0.73), label: "Bike-friendly road"),
        LegendItem(color: Color(red: 0.69, green: 0.95, blue: 0.95), label: "Shared (foot + bike)"),
        LegendItem(color: Color(red: 0.00, green: 0.38, blue: 1.00), label: "Cycle street"),
        LegendItem(color: Color(red: 0.96, green: 0.77, blue: 0.77), label: "Road, bikes allowed"),
        LegendItem(color: Color(red: 0.83, green: 0.83, blue: 0.83), label: "No cycling"),
    ]

    private func viewModeIcon(_ mode: ViewMode) -> String {
        switch mode { case .map: "map"; case .photos: "photo.stack"; case .script: "doc.text" }
    }
    private func viewModeLabel(_ mode: ViewMode, photoCount: Int) -> String {
        switch mode {
        case .map: "Map"
        case .photos: photoCount > 0 ? "Photos (\(photoCount))" : "Photos"
        case .script: "Script"
        }
    }
    /// Scripts only appear in the toggle when the open project actually has one.
    private var hasScripts: Bool {
        !(allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })?.scripts.isEmpty ?? true)
    }

    private var viewModeToggle: some View {
        let photoCount = locations.reduce(0) { $0 + $1.images.count }
        let modes: [ViewMode] = hasScripts ? [.map, .photos, .script] : [.map, .photos]
        return HStack(spacing: 2) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    withAnimation(.spring(duration: 0.3)) { viewMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: viewModeIcon(mode))
                            .font(.subheadline.weight(.medium))
                        Text(viewModeLabel(mode, photoCount: photoCount))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(viewMode == mode ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(.white.opacity(viewMode == mode ? 0.18 : 0))
                    )
                    .animation(.spring(duration: 0.25), value: viewMode)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
        .padding(.top, 14)
    }

    private var layersButton: some View {
        let active = mapStyle != .explore || cyclingProvider != nil
        return Button { showLayersPopover.toggle() } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? .blue : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help("Map Layers")
        .popover(isPresented: $showLayersPopover, arrowEdge: .top) {
            LayersPopover(mapStyle: $mapStyle, cyclingProviderRaw: $cyclingProviderRaw, pinSize: $pinSize)
        }
    }

    private var photosButton: some View {
        Button { showPhotoAnnotations.toggle() } label: {
            Image(systemName: showPhotoAnnotations ? "photo.fill" : "photo")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(showPhotoAnnotations ? .blue : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help(showPhotoAnnotations ? "Hide photos on pins" : "Show photos on pins")
    }

    private var boundaryButton: some View {
        let active = showPrefectures || showMunicipalities
        return Button { showBoundaryPopover.toggle() } label: {
            Image(systemName: "map")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? .orange : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help("Japan Boundaries")
        .popover(isPresented: $showBoundaryPopover, arrowEdge: .top) {
            BoundarySettingsPopover(
                showPrefectures: $showPrefectures,
                showMunicipalities: $showMunicipalities,
                showNames: $showBoundaryNames,
                opacity: $boundaryOpacity,
                nameLanguage: $boundaryNameLanguage,
                isLoadingPrefectures: isLoadingPrefectures,
                isLoadingMunicipalities: isLoadingMunicipalities,
                prefectureCount: prefectureBoundaries.count,
                municipalityCount: municipalityBoundaries.count,
                error: boundaryError
            )
            .onChange(of: showPrefectures) { _, on in
                if on { Task { await loadPrefectures() } }
                else { rebuildBoundaryPolygons() }
            }
            .onChange(of: showMunicipalities) { _, on in
                if on { Task { await loadMunicipalities() } }
                else { rebuildBoundaryPolygons() }
            }
        }
    }

    // MARK: - Boundary helpers

    private func rebuildBoundaryPolygons() {
        var result: [BoundaryPolygon] = []
        let japanActive: [JapanBoundaryService.BoundaryData] = (showPrefectures ? prefectureBoundaries : [])
            + (showMunicipalities ? municipalityBoundaries : [])
        for (idx, boundary) in japanActive.enumerated() {
            for ring in boundary.rings {
                guard ring.count >= 3 else { continue }
                var coords = ring
                let poly = BoundaryPolygon(coordinates: &coords, count: coords.count)
                poly.boundaryName = boundary.name
                poly.boundaryNameEn = boundary.nameEn
                poly.colorIndex = idx
                result.append(poly)
            }
        }
        // Active saved regions drawn as boundary overlays
        let activeRegions = savedRegions.filter(\.isActive)
        for (idx, region) in activeRegions.enumerated() {
            var coords = region.polygon
            guard coords.count >= 3 else { continue }
            let poly = BoundaryPolygon(coordinates: &coords, count: coords.count)
            poly.boundaryName = region.name
            poly.colorIndex = japanActive.count + idx
            result.append(poly)
        }
        cachedBoundaryPolygons = result
    }

    private func loadPrefectures() async {
        guard prefectureBoundaries.isEmpty else { return }
        isLoadingPrefectures = true
        boundaryError = nil
        do {
            prefectureBoundaries = try await JapanBoundaryService.shared.fetchPrefectures()
            rebuildBoundaryPolygons()
        } catch {
            boundaryError = "Prefectures: \(error.localizedDescription)"
            showPrefectures = false
        }
        isLoadingPrefectures = false
    }

    private func loadMunicipalities() async {
        isLoadingMunicipalities = true
        boundaryError = nil
        let region = mapController.mapView?.region
        let bbox = JapanBoundaryService.BoundingBox(
            south: (region?.center.latitude ?? 34) - (region?.span.latitudeDelta ?? 2) / 2,
            west:  (region?.center.longitude ?? 135) - (region?.span.longitudeDelta ?? 2) / 2,
            north: (region?.center.latitude ?? 34) + (region?.span.latitudeDelta ?? 2) / 2,
            east:  (region?.center.longitude ?? 135) + (region?.span.longitudeDelta ?? 2) / 2
        )
        do {
            municipalityBoundaries = try await JapanBoundaryService.shared.fetchMunicipalities(in: bbox)
            rebuildBoundaryPolygons()
        } catch {
            boundaryError = "Cities: \(error.localizedDescription)"
            showMunicipalities = false
        }
        isLoadingMunicipalities = false
    }

    private var lassoControls: some View {
        Button {
            searchArea.isDrawing.toggle()
        } label: {
            Image(systemName: searchArea.isDrawing ? "xmark.circle.fill" : "lasso")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(searchArea.isDrawing ? .red : searchArea.isActive ? .blue : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help(searchArea.isDrawing ? "Cancel" : searchArea.isActive ? "Redraw search area" : "Draw search area")
        // Clear button floats above without changing the row height
        .overlay(alignment: .top) {
            if searchArea.isActive {
                Button(action: searchArea.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear search area")
                .offset(y: -28)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.2), value: searchArea.isActive)
    }

    // MARK: - Search

    /// Current map/saved area, used to bias all searches toward what you're looking at.
    private var searchRegion: GooglePlacesService.MapRegion? {
        searchArea.mapRegion ??
        (hasSavedRegion ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta) : nil)
    }

    /// Runs the active source's search. Google/Flickr/Wikimedia share the same
    /// wrapper (loading state, area filtering, map fit); only the service call differs.
    @MainActor
    private func runSearch() async {
        guard rightPanelTab != .ai else { return }
        let requiresQuery: Bool = rightPanelTab == .google
        if requiresQuery && searchText.isEmpty { return }

        isSearching = true
        searchError = nil
        locations = []
        defer { isSearching = false }

        do {
            dlog("\(rightPanelTab.label) search: \"\(searchText)\"", level: .info, tag: "Search")
            var results: [ScoutLocation]
            switch rightPanelTab {
            case .google:
                results = try await GooglePlacesService.shared.search(query: searchText, region: searchRegion)
            case .foursquare:
                results = try await FoursquareService.shared.search(query: searchText.isEmpty ? nil : searchText, region: searchRegion, limit: Int(foursquareLimit))
            case .flickr:
                results = try await FlickrService.shared.search(query: searchText.isEmpty ? nil : searchText, region: searchRegion, limit: Int(flickrLimit))
            case .wikimedia:
                results = try await WikimediaService.shared.search(query: searchText, region: searchRegion, limit: Int(wikiLimit))
            case .ai:
                return
            }
            if searchArea.isActive { results = results.filter { searchArea.contains($0.coordinate) } }
            locations = results
            selectedLocation = nil
            dlog("\(rightPanelTab.label) returned \(results.count) results", level: .success, tag: "Search")
        } catch {
            searchError = error.localizedDescription
        }
        if !locations.isEmpty { fitMapToResults() }
    }

    @MainActor
    private func runAISearch(query: String, model: ClaudeModel = .opus, extendedThinking: Bool = false) async {
        guard !query.isEmpty else { return }
        isAISearching = true
        searchError = nil
        locations = []
        chatMessages.append(.user(text: query))
        do {
            let aiRegion: GooglePlacesService.MapRegion?
            if searchArea.isActive {
                aiRegion = searchArea.mapRegion
            } else if aiConstrainToMap && hasSavedRegion {
                aiRegion = .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta)
            } else {
                aiRegion = nil
            }
            try await ClaudeService.shared.searchLocations(
                query: query,
                model: model.rawValue,
                extendedThinking: extendedThinking,
                mapRegion: aiRegion,
                onLocation: { location in
                    Task { @MainActor in
                        if self.searchArea.isActive && !self.searchArea.contains(location.coordinate) { return }
                        self.locations.append(location)
                    }
                },
                onStatus: { status in
                    Task { @MainActor in self.chatMessages.append(.status(text: status)) }
                }
            )
            chatMessages.append(.result(count: locations.count))
        } catch {
            chatMessages.append(.error(text: error.localizedDescription))
        }
        isAISearching = false
        if !locations.isEmpty { fitMapToResults() }
        // Refresh cost display now that we've consumed tokens
        let adminKey = APIKeyState.shared.anthropicAdminKey
        if !adminKey.isEmpty {
            await UsageCostService.shared.refresh(adminKey: adminKey)
        }
    }

    private func fitMapToResults() {
        let coords = locations.map(\.coordinate)
        mapController.fit(coords, animated: true)
    }

    /// Frames every GPS pin in the open project (active-list pins, project photos, and
    /// unfiled pins — i.e. everything currently on the map for this project). Bound to "f".
    private func frameAllProjectPins() {
        let coords = cachedProjectPins.map { $0.0.coordinate }
        guard !coords.isEmpty else { return }
        mapController.fit(coords, animated: true)
    }

    /// Clears the current search results everywhere they appear: the right-panel list,
    /// the map pins, and the "Search Results" section of the photo grid (all driven by
    /// the shared `locations` state).
    private func clearSearchResults() {
        locations = []
        selectedLocation = nil
    }
}

// MARK: - Supporting Views

// MARK: - Saved region model

struct SavedRegion: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var polygon: [CLLocationCoordinate2D]
    var isActive: Bool

    init(name: String, polygon: [CLLocationCoordinate2D], isActive: Bool) {
        self.name = name
        self.polygon = polygon
        self.isActive = isActive
    }

    static func == (lhs: SavedRegion, rhs: SavedRegion) -> Bool {
        lhs.id == rhs.id && lhs.isActive == rhs.isActive
    }

    // CLLocationCoordinate2D isn't Codable, so the polygon is stored as a flat
    // [lat, lng, lat, lng, …] array for persistence.
    enum CodingKeys: String, CodingKey { case id, name, polygon, isActive }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        let flat = (try? c.decode([Double].self, forKey: .polygon)) ?? []
        var coords: [CLLocationCoordinate2D] = []
        var i = 0
        while i + 1 < flat.count {
            coords.append(.init(latitude: flat[i], longitude: flat[i + 1]))
            i += 2
        }
        polygon = coords
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(polygon.flatMap { [$0.latitude, $0.longitude] }, forKey: .polygon)
    }
}

// MARK: - Region toggle chip

private struct RegionChip: View {
    let name: String
    let isActive: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? .white : .primary)
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(isActive ? Color.blue : Color.primary.opacity(0.08),
                    in: Capsule())
        .overlay(Capsule().stroke(isActive ? Color.clear : Color.primary.opacity(0.15), lineWidth: 0.5))
        .onTapGesture(perform: onToggle)
    }
}

/// A thin draggable divider between the left sidebar and the center panel. Hovering shows
/// the horizontal-resize cursor (macOS); dragging adjusts the bound width within [min, max].
private struct SidebarResizeHandle: View {
    /// Current width (the live value during a drag, or the persisted value at rest).
    let width: Double
    let minWidth: Double
    let maxWidth: Double
    /// Fired every drag tick with the new live width — drives a plain @State, no persistence.
    let onLiveChange: (Double) -> Void
    /// Fired once on drag end with the final width — this is where it's persisted.
    let onCommit: (Double) -> Void
    @State private var dragStartWidth: Double? = nil

    private func clamp(_ w: Double) -> Double { min(max(w, minWidth), maxWidth) }

    var body: some View {
        Divider()
            .frame(width: 1)
            .overlay(
                // Wider invisible hit area so the 1px line is easy to grab. It's an overlay,
                // so widening it doesn't shift layout — it just makes the cursor/grab zone bigger.
                Color.clear
                    .frame(width: 16)
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    #endif
                    // Global coordinate space: the handle moves as the sidebar resizes, so a
                    // .local translation would be measured against a frame that's shifting
                    // under the cursor — that feedback loop makes the drag oscillate. Global
                    // (screen) coordinates are stable regardless of the handle's own movement.
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let base = dragStartWidth ?? width
                                if dragStartWidth == nil { dragStartWidth = width }
                                onLiveChange(clamp(base + value.translation.width))
                            }
                            .onEnded { value in
                                let base = dragStartWidth ?? width
                                onCommit(clamp(base + value.translation.width))
                                dragStartWidth = nil
                            }
                    )
            )
    }
}

/// The one card used to show a location everywhere — sidebar search results and
/// saved-list rows alike. Purely visual and driven by a `ScoutLocation`; callers
/// attach their own behavior (drag, drop, tap, context menus) around it.
struct LocationRow: View {
    let location: ScoutLocation
    var showsPhotos: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsPhotos, !location.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(location.images) { image in
                            if let url = image.url {
                                GooglePhotoImage(url: url) {
                                    Color.secondary.opacity(0.1)
                                        .overlay(ProgressView().controlSize(.mini))
                                }
                                .scaledToFill()
                                .frame(width: 100, height: 70)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 74)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }

            Text(location.name)
                .font(.headline)
                .lineLimit(1)

            if !location.description.isEmpty {
                Text(location.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Label(location.status.rawValue, systemImage: location.status.icon)
                    .font(.caption2)
                    .foregroundStyle(location.status.color)
                Spacer()
                if let url = location.googleMapsURL {
                    Link(destination: url) {
                        Image(systemName: "map").font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension View {
    /// Floating map-control chrome: material fill, soft shadow, fixed square.
    func mapControlChrome(diameter: CGFloat = 36, circle: Bool = true) -> some View {
        frame(width: diameter, height: diameter)
            .background(.regularMaterial, in: circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
    }
}

extension LocationStatus {
    var icon: String {
        switch self {
        case .scouted: "mappin.circle"
        case .shortlisted: "star.circle"
        case .approved: "checkmark.circle.fill"
        case .rejected: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .scouted: .secondary
        case .shortlisted: .orange
        case .approved: .green
        case .rejected: .red
        }
    }
}

// MARK: - Right panel tabs

enum RightPanelTab: String, CaseIterable, Identifiable {
    case ai, google, foursquare, flickr, wikimedia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ai:          "AI"
        case .google:      "Google"
        case .foursquare:  "4Square"
        case .flickr:      "Flickr"
        case .wikimedia:   "Wiki"
        }
    }

    var icon: String {
        switch self {
        case .ai:          "sparkles"
        case .google:      "map"
        case .foursquare:  "mappin.and.ellipse"
        case .flickr:      "camera"
        case .wikimedia:   "globe"
        }
    }

    var placeholder: String {
        switch self {
        case .ai:          ""
        case .google:      "Search Google Maps…"
        case .foursquare:  "Search Foursquare…"
        case .flickr:      "Search Flickr photos…"
        case .wikimedia:   "Search Wikimedia Commons…"
        }
    }

    var emptyHint: String {
        switch self {
        case .ai:          "Ask AI Scout for locations"
        case .google:      "Search Google Maps above"
        case .foursquare:  "Search Foursquare above"
        case .flickr:      "Search for geotagged Flickr photos"
        case .wikimedia:   "Search for geotagged Commons photos"
        }
    }

    var emptyIcon: String {
        switch self {
        case .ai:         "sparkles"
        case .google:     "mappin.slash"
        case .foursquare: "mappin.and.ellipse"
        case .flickr:     "camera"
        case .wikimedia:  "globe"
        }
    }
}

// MARK: - View mode

enum ViewMode: CaseIterable {
    case map, photos, script
}

// MARK: - Map style

enum MapStyle: String, CaseIterable, Identifiable {
    case explore, satellite, hybrid, muted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .explore:   "Explore"
        case .satellite: "Satellite"
        case .hybrid:    "Hybrid"
        case .muted:     "Muted"
        }
    }

    var icon: String {
        switch self {
        case .explore:   "map"
        case .satellite: "globe.americas"
        case .hybrid:    "globe.americas.fill"
        case .muted:     "square.dashed"
        }
    }

    // Thumbnail card background
    var cardBackground: Color {
        switch self {
        case .explore:   Color(.sRGB, red: 0.87, green: 0.93, blue: 0.82)
        case .satellite: Color(.sRGB, red: 0.12, green: 0.22, blue: 0.16)
        case .hybrid:    Color(.sRGB, red: 0.18, green: 0.28, blue: 0.22)
        case .muted:     Color(.sRGB, red: 0.88, green: 0.87, blue: 0.85)
        }
    }

    var iconColor: Color {
        switch self {
        case .explore:   .green
        case .satellite: .white
        case .hybrid:    .white
        case .muted:     .secondary
        }
    }

    var mapType: MKMapType {
        switch self {
        case .explore:   .standard
        case .satellite: .satellite
        case .hybrid:    .hybrid
        case .muted:     .mutedStandard
        }
    }
}

// MARK: - Layers popover

struct LayersPopover: View {
    @Binding var mapStyle: MapStyle
    @Binding var cyclingProviderRaw: String
    @Binding var pinSize: Double

    private var cyclingProvider: CyclingTileProvider? {
        CyclingTileProvider(rawValue: cyclingProviderRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Map type ──────────────────────────────────
            Text("Map Type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                ForEach(MapStyle.allCases) { style in
                    styleCard(style)
                }
            }
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 12)

            // ── Pins ──────────────────────────────────────
            Text("Pins")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                Label("Size", systemImage: "circle.dotted")
                    .font(.subheadline)
                Slider(value: $pinSize, in: 0.5...2.5)
                    .controlSize(.small)
                Text("\(Int(pinSize * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider().padding(.bottom, 12)

            // ── Overlays ──────────────────────────────────
            Text("Overlays")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                // Cycling toggle header
                HStack {
                    Label("Cycling", systemImage: "bicycle")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { cyclingProvider != nil },
                        set: { on in
                            cyclingProviderRaw = on ? CyclingTileProvider.cyclOSM.rawValue : ""
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                // Sub-options when cycling is on
                if cyclingProvider != nil {
                    Divider().padding(.leading, 12)
                    ForEach(CyclingTileProvider.allCases) { provider in
                        Button {
                            cyclingProviderRaw = provider.rawValue
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(provider.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(provider.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cyclingProvider == provider {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if provider != CyclingTileProvider.allCases.last {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 268)
    }

    private func styleCard(_ style: MapStyle) -> some View {
        let isSelected = mapStyle == style
        return Button { mapStyle = style } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(style.cardBackground)
                    Image(systemName: style.icon)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(style.iconColor)
                }
                .frame(height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

                Text(style.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

// MARK: - Boundary settings popover

struct BoundarySettingsPopover: View {
    @Binding var showPrefectures: Bool
    @Binding var showMunicipalities: Bool
    @Binding var showNames: Bool
    @Binding var opacity: Double
    @Binding var nameLanguage: BoundaryNameLanguage

    let isLoadingPrefectures: Bool
    let isLoadingMunicipalities: Bool
    let prefectureCount: Int
    let municipalityCount: Int
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Japan Boundaries")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Boundary Level").font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)

                HStack {
                    Toggle(isOn: $showPrefectures) {
                        HStack(spacing: 4) {
                            Text("Prefectures")
                            if isLoadingPrefectures { ProgressView().controlSize(.mini) }
                            else if prefectureCount > 0 { Text("(\(prefectureCount))").foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    Spacer()
                }
                HStack {
                    Toggle(isOn: $showMunicipalities) {
                        HStack(spacing: 4) {
                            Text("Cities / Towns")
                            if isLoadingMunicipalities { ProgressView().controlSize(.mini) }
                            else if municipalityCount > 0 { Text("(\(municipalityCount))").foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    Spacer()
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Display").font(.caption).foregroundStyle(.secondary)

                Toggle("Show Names", isOn: $showNames)

                if showNames {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name language").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(BoundaryNameLanguage.allCases, id: \.self) { lang in
                                Toggle(isOn: Binding(
                                    get: { nameLanguage == lang },
                                    set: { if $0 { nameLanguage = lang } }
                                )) {
                                    Text(lang.label).font(.caption)
                                }
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }

                HStack {
                    Text("Fill Opacity").font(.subheadline)
                    Spacer()
                    Text("\(Int(opacity * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0.02...0.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.15), value: showNames)
        }
        .frame(width: 260)
    }
}

#if DEBUG
#Preview("Main layout", traits: .fixedLayout(width: 1200, height: 800)) {
    ContentView()
        .environmentObject(APIKeyState.shared)
        .modelContainer(PreviewData.container)
        .onAppear {
            #if os(macOS)
            NSApp.windows.forEach { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
            }
            #endif
        }
}

#Preview("Location row") {
    List {
        LocationRow(location: .preview)
        LocationRow(location: .previewNoPhotos)
        LocationRow(location: .preview, showsPhotos: false)
    }
    .frame(width: 320, height: 360)
}

#Preview("Layers popover") {
    @Previewable @State var style = MapStyle.explore
    @Previewable @State var cycling = ""
    @Previewable @State var size = 1.0
    LayersPopover(mapStyle: $style, cyclingProviderRaw: $cycling, pinSize: $size)
}

#Preview("Boundary popover") {
    @Previewable @State var prefectures = true
    @Previewable @State var municipalities = false
    @Previewable @State var names = true
    @Previewable @State var opacity = 0.2
    @Previewable @State var language = BoundaryNameLanguage.japanese
    BoundarySettingsPopover(
        showPrefectures: $prefectures,
        showMunicipalities: $municipalities,
        showNames: $names,
        opacity: $opacity,
        nameLanguage: $language,
        isLoadingPrefectures: false,
        isLoadingMunicipalities: false,
        prefectureCount: 47,
        municipalityCount: 0,
        error: nil
    )
}
#endif
