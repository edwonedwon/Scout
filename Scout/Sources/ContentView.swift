import SwiftUI
import MapKit
import SwiftData
import ScoutKit


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
    // Cached pin arrays so asScoutLocation() isn't called on every ContentView body render.
    // Rebuilt only when the underlying SwiftData queries or activeListIDs actually change.
    @State private var cachedProjectPins: [(ScoutLocation, String)] = []
    @State private var cachedAllProjectPins: [ScoutLocation] = []
    @State private var cachedGridSections: [PhotoGridView.Section] = []
    /// When non-nil, this stackID is expanded on the map — all member pins are shown individually.
    @State private var expandedStackID: UUID? = nil
    /// UUIDs to move when the move sheet is triggered from the grid or M key outside sidebar.
    @State private var externalMoveUUIDs: [UUID] = []
    /// Option-click multi-selection of map pins (location IDs).
    @State private var mapSelection: Set<UUID> = []

    private var hasSavedRegion: Bool {
        !savedLat.isNaN && !savedLng.isNaN
    }

    /// Lists scoped to the currently open project, or all lists if no project is open.
    private var openProjectLists: [LocationListData] {
        guard !openProjectUUID.isEmpty,
              let project = allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })
        else { return [] }
        return project.lists
    }

    private var initialRegion: MKCoordinateRegion? {
        guard hasSavedRegion else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: savedLat, longitude: savedLng),
            span: MKCoordinateSpan(latitudeDelta: savedLatDelta, longitudeDelta: savedLngDelta)
        )
    }

    var body: some View {
        rootLayoutWithObservers
    }

    @ViewBuilder private var rootLayoutWithObservers: some View {
        rootLayoutWithModeObservers
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
                if newMode == .map { highlightedPinID = nil }
                if newMode == .photos {
                    selectedLocation = nil
                    mapController.dismissPopover()
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
    }

    @ViewBuilder private var rootLayout: some View {
        HStack(spacing: 0) {
            if showProjectsPanel {
                ProjectsPanel(
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
                    scrollToPinUUID: highlightedPinID,
                    externalMoveUUIDs: $externalMoveUUIDs
                )
                .frame(width: 240)
                .transition(.move(edge: .leading))
                Divider()
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
        rebuildPinCaches()
        locations = []
        modelContext.undoManager = undoManager
        locationManager.requestIfNeeded()
        centerOnUserIfNeeded()
        backfillPhotos()
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
                locations: locations,
                pinnedSections: cachedGridSections,
                highlightedLocationID: highlightedPinID,
                onClearSearchResults: clearSearchResults,
                onSelectLocation: { id in highlightedPinID = id },
                onDoubleSelectLocation: { id in
                    if let pin = allPins.first(where: { $0.uuid == id }) {
                        openInCarousel(pin)
                    }
                },
                onMakeStackFromGrid: { uuids in
                    let pins = uuids.compactMap { id in allPins.first(where: { $0.uuid == id }) }
                    guard pins.count >= 2 else { return }
                    let stackID = UUID()
                    for pin in pins { pin.stackID = stackID }
                    try? modelContext.save()
                    rebuildPinCaches()
                },
                onMoveToList: { uuids in externalMoveUUIDs = uuids },
                onRotate: { uuids in rotatePins(uuids) },
                originalFilePath: { id in allPins.first(where: { $0.uuid == id })?.originalFilePath }
            )
                .ignoresSafeArea()
                .opacity(viewMode == .photos ? 1 : 0)
                .allowsHitTesting(viewMode == .photos)
                .zIndex(10)
            if photoViewer.isVisible {
                PhotoViewerOverlay(availableLists: openProjectLists, onSave: savePinned,
                                   onRotate: { url in rotatePin(forImageURL: url) })
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: photoViewer.isVisible)
                    .zIndex(20)
            }
        }
        // M key: open move sheet from photo grid or map selection (sidebar handles its own M).
        .background {
            Button("") {
                let uuids: [UUID] = {
                    // Map option-click multi-selection wins, then highlighted grid/map pin.
                    if !mapSelection.isEmpty { return Array(mapSelection) }
                    if let id = highlightedPinID { return [id] }
                    if let id = selectedLocation?.id { return [id] }
                    return []
                }()
                if !uuids.isEmpty { externalMoveUUIDs = uuids }
            }
            .keyboardShortcut("m", modifiers: [])
            .opacity(0)
            .allowsHitTesting(false)
        }
        // Clear the map multi-selection once the move sheet has closed.
        .onChange(of: externalMoveUUIDs) { _, ids in
            if ids.isEmpty { mapSelection = [] }
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
                        icon: showRightPanel ? "sidebar.right" : "rectangle.rightthird.inset.filled",
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
            Image(systemName: "crop")
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

    private func panelToggleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .mapControlChrome(diameter: 32, circle: false)
        }
        .buttonStyle(.plain)
    }

    private static let generalPinColor = ""   // empty = no border for uncategorized pins

    /// Changes whenever any pin's list membership or sort order changes, even when total
    /// counts are unchanged — used to trigger a grid rebuild after drag-reorder.
    private var pinListAssignmentHash: Int {
        allPins.reduce(0) { acc, pin in
            let listHash = pin.list?.persistentModelID.hashValue ?? 0
            return acc ^ listHash ^ pin.sortOrder ^ pin.panelOrder
        }
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

    private func rebuildPinCaches() {
        let active = allLists.filter { activeListIDs.contains($0.persistentModelID) }
        var mapPins: [(ScoutLocation, String)] = active.flatMap { list in
            list.pins.filter { $0.hasGPS }.map { ($0.asScoutLocation(), list.colorHex) }
        }
        for project in allProjects {
            // Skip uncategorized pins for projects whose "Uncategorized" eye is off.
            guard !hiddenUncategorizedProjectIDs.contains(project.persistentModelID) else { continue }
            var seenStacks: Set<UUID> = []
            // Pre-group expanded stack members so we can index them for radial spread.
            let expandedMembers: [UUID: [PinnedLocationData]] = {
                guard let sid = expandedStackID else { return [:] }
                let members = project.importedPhotos.filter { $0.stackID == sid && $0.hasGPS }
                    .sorted { $0.sortOrder < $1.sortOrder }
                return members.isEmpty ? [:] : [sid: members]
            }()
            for pin in project.importedPhotos where pin.hasGPS {
                if let sid = pin.stackID {
                    if sid == expandedStackID, let members = expandedMembers[sid] {
                        // Spread members in a small circle so pins don't stack on one point.
                        let idx = members.firstIndex(where: { $0.uuid == pin.uuid }) ?? 0
                        let count = members.count
                        let spreadMeters: Double = count > 1 ? 8.0 : 0
                        let angle = (2 * Double.pi / Double(count)) * Double(idx)
                        let dLat = (spreadMeters / 111_000) * cos(angle)
                        let dLng = (spreadMeters / (111_000 * cos(pin.latitude * .pi / 180))) * sin(angle)
                        var loc = pin.asScoutLocation()
                        let coord = CLLocationCoordinate2D(latitude: loc.coordinate.latitude + dLat,
                                                           longitude: loc.coordinate.longitude + dLng)
                        loc = ScoutLocation(id: loc.id, name: loc.name, description: loc.description,
                                            coordinate: coord, groupID: loc.groupID,
                                            sourceURL: loc.sourceURL, images: loc.images,
                                            fullResImages: loc.fullResImages,
                                            googleMapsURL: loc.googleMapsURL,
                                            googlePlaceId: loc.googlePlaceId)
                        mapPins.append((loc, Self.generalPinColor))
                    } else {
                        // Stack is collapsed — only show the lead pin once.
                        guard seenStacks.insert(sid).inserted else { continue }
                        mapPins.append((pin.asScoutLocation(), Self.generalPinColor))
                    }
                } else {
                    mapPins.append((pin.asScoutLocation(), Self.generalPinColor))
                }
            }
        }
        mapPins += unfiledPins.filter { $0.hasGPS }.map { ($0.asScoutLocation(), Self.generalPinColor) }
        cachedProjectPins = mapPins

        // Flat list kept for places that still need it (annotation building etc.)
        var gridPins: [ScoutLocation] = active.flatMap { $0.pins }.map { $0.asScoutLocation() }
        for project in allProjects {
            gridPins += project.importedPhotos.map { $0.asScoutLocation() }
        }
        gridPins += unfiledPins.map { $0.asScoutLocation() }
        cachedAllProjectPins = gridPins

        // Sectioned grid matching sidebar order: lists inside projects, then unfiled.
        var sections: [PhotoGridView.Section] = []
        for project in allProjects.sorted(by: { $0.createdAt < $1.createdAt }) {
            // Lists inside this project (sidebar panel order). Only visible lists (eye on).
            let sortedLists = project.lists
                .filter { activeListIDs.contains($0.persistentModelID) }
                .sorted { $0.panelOrder < $1.panelOrder }
            for list in sortedLists {
                let locs = list.pins
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .map { $0.asScoutLocation() }
                    .filter { !$0.images.isEmpty }
                if !locs.isEmpty {
                    sections.append(PhotoGridView.Section(
                        title: project.lists.count > 1 ? "\(project.name) — \(list.name)" : project.name,
                        locations: locs,
                        color: Color(hexString: list.colorHex)
                    ))
                }
            }
            // Directly-imported photos (no list). Deduplicate stacks — show only lead pin.
            // Skipped entirely when this project's "Uncategorized" eye is off.
            var seenStacksGrid: Set<UUID> = []
            let imported = hiddenUncategorizedProjectIDs.contains(project.persistentModelID)
                ? []
                : project.importedPhotos
                .sorted { $0.sortOrder < $1.sortOrder }
                .filter { pin in
                    if let sid = pin.stackID {
                        return seenStacksGrid.insert(sid).inserted
                    }
                    return true
                }
                .map { $0.asScoutLocation() }
                .filter { !$0.images.isEmpty }
            if !imported.isEmpty {
                let title = project.lists.isEmpty ? project.name : "\(project.name) — Uncategorized"
                sections.append(PhotoGridView.Section(title: title, locations: imported))
            }
        }
        // Active standalone lists not belonging to any project.
        for list in active.filter({ $0.project == nil }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let locs = list.pins
                .sorted { $0.sortOrder < $1.sortOrder }
                .map { $0.asScoutLocation() }
                .filter { !$0.images.isEmpty }
            if !locs.isEmpty {
                sections.append(PhotoGridView.Section(
                    title: list.name,
                    locations: locs,
                    color: Color(hexString: list.colorHex)
                ))
            }
        }
        // Unfiled pins.
        let unfiled = unfiledPins
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { $0.asScoutLocation() }
            .filter { !$0.images.isEmpty }
        if !unfiled.isEmpty {
            sections.append(PhotoGridView.Section(title: "Uncategorized", locations: unfiled))
        }
        cachedGridSections = sections
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
        // If this pin belongs to a stack, gather all stack members' images into one location.
        let location: ScoutLocation
        if let stackID = pin.stackID {
            let members = allPins.filter { $0.stackID == stackID }
                .sorted { $0.sortOrder < $1.sortOrder }
            let allImages = members.flatMap { m -> [ScoutImage] in
                let loc = m.asScoutLocation()
                return loc.fullResImages.isEmpty ? loc.images : loc.fullResImages
            }
            let base = pin.asScoutLocation()
            location = ScoutLocation(id: base.id, name: base.name, description: base.description,
                                     coordinate: base.coordinate, sourceURL: base.sourceURL,
                                     images: allImages, googleMapsURL: base.googleMapsURL,
                                     googlePlaceId: base.googlePlaceId)
        } else {
            location = pin.asScoutLocation()
        }
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
        list.pins.append(pin)
        pin.list = list
        // owningProject must stay nil for list pins — it's the inverse of importedPhotos,
        // so setting it would add the pin back to the project top-level as a duplicate.
        try? modelContext.save()
    }

    /// Download a saved pin's photos to disk and capture its source links, so it displays
    /// offline (never refetches) and shows its Google Maps / source link in the popover.
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
            mapSelection: $mapSelection,
            locations: locations,
            projectPins: cachedProjectPins,
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
            onStackTapped: { stackID in
                if expandedStackID == stackID {
                    expandedStackID = nil
                } else {
                    expandedStackID = stackID
                }
                rebuildPinCaches()
            },
            onMapDeselect: {
                if expandedStackID != nil {
                    expandedStackID = nil
                    rebuildPinCaches()
                }
            },
            mapType: mapStyle.mapType,
            cyclingProvider: cyclingProvider,
            showPhotoAnnotations: showPhotoAnnotations,
            pinScale: pinSize,
            availableLists: openProjectLists,
            onSaveToList: saveToList,
            onAddTagToSelection: { if !mapSelection.isEmpty { externalMoveUUIDs = Array(mapSelection) } },
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
            DebugPanelOverlay(onDeleteAllData: deleteAllData)
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

    private var viewModeToggle: some View {
        let photoCount = locations.reduce(0) { $0 + $1.images.count }
        return HStack(spacing: 2) {
            ForEach([ViewMode.map, .photos], id: \.self) { mode in
                Button {
                    withAnimation(.spring(duration: 0.3)) { viewMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode == .map ? "map" : "photo.stack")
                            .font(.subheadline.weight(.medium))
                        Text(mode == .map ? "Map" : (photoCount > 0 ? "Photos (\(photoCount))" : "Photos"))
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

struct SavedRegion: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var polygon: [CLLocationCoordinate2D]
    var isActive: Bool

    static func == (lhs: SavedRegion, rhs: SavedRegion) -> Bool {
        lhs.id == rhs.id && lhs.isActive == rhs.isActive
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
    case map, photos
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
            NSApp.windows.forEach { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
            }
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
