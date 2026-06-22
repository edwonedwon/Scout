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
    @AppStorage("flickr.limit") private var flickrLimit: Double = 50
    @State private var showLayersPopover = false
    @AppStorage("map.showPhotoAnnotations") private var showPhotoAnnotations = false
    @AppStorage("map.pinSize") private var pinSize: Double = 1.0
    @State private var regionQuery = ""
    @State private var regionName: String? = nil
    @State private var isRegionSearching = false

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
    @Query(sort: \LocationListData.createdAt) private var allLists: [LocationListData]
    // General pins not attached to any list — always shown on the map.
    @Query(filter: #Predicate<PinnedLocationData> { $0.list == nil }, sort: \PinnedLocationData.createdAt)
    private var unfiledPins: [PinnedLocationData]
    // All pins, for the one-time offline-photo backfill.
    @Query private var allPins: [PinnedLocationData]

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isAISearching = false
    @State private var locations: [ScoutLocation] = []
    @State private var selectedLocation: ScoutLocation?
    @State private var searchError: String?
    @State private var didInitialCenter = false
    @State private var chatMessages: [ChatMessage] = []
    @State private var viewMode: ViewMode = .map
    @State private var showProjectsPanel = false
    @State private var showRightPanel = true
    @State private var activeListIDs: Set<PersistentIdentifier> = []

    private var hasSavedRegion: Bool {
        !savedLat.isNaN && !savedLng.isNaN
    }

    private var initialRegion: MKCoordinateRegion? {
        guard hasSavedRegion else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: savedLat, longitude: savedLng),
            span: MKCoordinateSpan(latitudeDelta: savedLatDelta, longitudeDelta: savedLngDelta)
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if showProjectsPanel {
                ProjectsPanel(
                    activeListIDs: $activeListIDs,
                    onFitToList: { pins in
                        let coords = pins.map(\.coordinate)
                        guard !coords.isEmpty else { return }
                        mapController.fit(coords, animated: true)
                    },
                    onSelectPin: selectPin
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
            // App-wide Escape handler (hidden). Carousel → grid → map → grid…
            Button("", action: handleEscape)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .allowsHitTesting(false)
        }
        .onAppear {
            locationManager.requestIfNeeded()
            centerOnUserIfNeeded()
            backfillPhotos()
            photoViewer.onViewOnMap = { loc in
                withAnimation(.spring(duration: 0.3)) { viewMode = .map }
                selectedLocation = loc
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    mapController.center(on: loc.coordinate, animated: true)
                }
            }
        }
        .onChange(of: locationManager.currentLocation?.latitude) { _, _ in
            centerOnUserIfNeeded()
        }
        .onChange(of: rightPanelTab) { _, _ in
            locations = []
            selectedLocation = nil
        }
        .onChange(of: viewMode) { _, newMode in
            if newMode == .photos && photoViewer.restoreOnPhotoMode {
                photoViewer.restoreOnPhotoMode = false
                photoViewer.isVisible = true
            }
        }
    }

    /// Escape cycles through the view contexts:
    /// carousel → photo grid, photo grid → map, map → photo grid.
    private func handleEscape() {
        if photoViewer.isVisible {
            photoViewer.dismiss()
            withAnimation(.spring(duration: 0.3)) { viewMode = .photos }
            return
        }
        withAnimation(.spring(duration: 0.3)) {
            viewMode = (viewMode == .map) ? .photos : .map
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
            .padding(.top, 10)
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
                        let canBrowse = rightPanelTab == .wikimedia || rightPanelTab == .flickr
                        if canBrowse || !searchText.isEmpty { Task { await runSearch() } }
                    }
                Button { Task { await runSearch() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled((searchText.isEmpty && rightPanelTab != .wikimedia && rightPanelTab != .flickr) || isSearching)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, (rightPanelTab == .wikimedia || rightPanelTab == .flickr) ? 4 : 8)

            if rightPanelTab == .wikimedia || rightPanelTab == .flickr {
                Button {
                    Task { await runSearch() }
                } label: {
                    Label("Browse photos in this area", systemImage: "photo.on.rectangle.angled")
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
                        value: rightPanelTab == .flickr ? $flickrLimit : $wikiLimit,
                        in: 10...500, step: 10
                    )
                    Text("\(Int(rightPanelTab == .flickr ? flickrLimit : wikiLimit))")
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
                        locations = []
                        selectedLocation = nil
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
                        if !allLists.isEmpty {
                            Menu {
                                ForEach(allLists) { list in
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
            PhotoGridView(locations: locations, pinnedLocations: projectPins.map(\.0).filter { !$0.images.isEmpty })
                .ignoresSafeArea()
                .opacity(viewMode == .photos ? 1 : 0)
                .allowsHitTesting(viewMode == .photos)
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
        .overlay {
            if photoViewer.isVisible {
                PhotoViewerOverlay(availableLists: allLists, onSave: savePinned)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: photoViewer.isVisible)
            }
        }
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

    private static let generalPinColor = "#E53935"   // red for unfiled pins

    private var projectPins: [(ScoutLocation, String)] {
        let active = allLists.filter { activeListIDs.contains($0.persistentModelID) }
        var result = active.flatMap { list in
            list.pins.map { ($0.asScoutLocation(), list.colorHex) }
        }
        // General (unfiled) pins are always visible, with a default color.
        result += unfiledPins.map { ($0.asScoutLocation(), Self.generalPinColor) }
        return result
    }

    /// Tapping a saved pin in the sidebar selects it on the map and shows its popover —
    /// exactly as if it were clicked on the map. Activates its list first so it's visible
    /// (unfiled pins are always shown), then centers on it.
    private func selectPin(_ pin: PinnedLocationData) {
        if let listID = pin.list?.persistentModelID {
            activeListIDs.insert(listID)
        }
        let location = pin.asScoutLocation()
        selectedLocation = location
        mapController.pan(to: location.coordinate, animated: true)
    }

    private func saveToList(_ location: ScoutLocation, _ list: LocationListData) {
        let pin = PinnedLocationData(from: location, sortOrder: list.pins.count)
        modelContext.insert(pin)
        pin.list = list   // inverse relationship adds it to list.pins
        cachePhotos(for: pin, from: location)
    }

    /// Save from the carousel: to a chosen list, or as a general unfiled pin (list == nil).
    private func savePinned(_ location: ScoutLocation, to list: LocationListData?) {
        if let list {
            saveToList(location, list)
        } else {
            let pin = PinnedLocationData(from: location)
            modelContext.insert(pin)   // list stays nil → general pin
            cachePhotos(for: pin, from: location)
        }
    }

    /// Download a saved pin's photos to disk so it displays offline and never refetches.
    private func cachePhotos(for pin: PinnedLocationData, from location: ScoutLocation) {
        let placeId = pin.googlePlaceId
        let uuid = pin.uuid
        Task { @MainActor in
            let files = await PinPhotoStore.download(for: location, placeId: placeId, pinUUID: uuid)
            guard !files.isEmpty else { return }
            pin.photoFiles = files
            try? modelContext.save()
        }
    }

    /// One-time pass over existing pins that have no offline photos yet, fetching them
    /// from their original source (stored URLs, Google place ID, or a name+area search).
    private func backfillPhotos() {
        for pin in allPins where pin.photoFiles.isEmpty {
            cachePhotos(for: pin, from: pin.asScoutLocation())
        }
    }

    private var scoutMap: some View {
        ScoutMapView(
            selection: $selectedLocation,
            locations: locations,
            projectPins: projectPins,
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
            mapType: mapStyle.mapType,
            cyclingProvider: cyclingProvider,
            showPhotoAnnotations: showPhotoAnnotations,
            pinScale: pinSize,
            availableLists: allLists,
            onSaveToList: saveToList,
            boundaryPolygons: cachedBoundaryPolygons,
            boundaryOpacity: boundaryOpacity,
            showBoundaryNames: showBoundaryNames,
            boundaryNameLanguage: boundaryNameLanguage
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            if let error = searchError {
                Text(error)
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    .padding()
            }
        }
        .overlay(alignment: .topLeading) {
            DebugPanelOverlay()
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
                if cyclingProvider == .cyclOSM {
                    cyclOSMLegend
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: cyclingProvider == .cyclOSM)
        }
    }

    private var regionSearchOverlay: some View {
        HStack(spacing: 4) {
            Image(systemName: "globe.europe.africa")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(regionName != nil ? .blue : .primary)

            TextField("Country, state, city…", text: $regionQuery)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 140)
                .onSubmit { Task { await runRegionSearch() } }

            if isRegionSearching {
                ProgressView().controlSize(.mini)
            } else if !regionQuery.isEmpty || regionName != nil {
                Button {
                    regionQuery = ""
                    regionName = nil
                    searchArea.clear()
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
                .stroke(regionName != nil ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
        // Found-region label floats above the pill without changing the row height
        .overlay(alignment: .topLeading) {
            if let name = regionName {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                    .fixedSize()
                    .offset(y: -22)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: regionName)
    }

    @MainActor
    private func runRegionSearch() async {
        let q = regionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isRegionSearching = true
        do {
            let result = try await NominatimService.shared.search(q)
            searchArea.setPolygon(result.polygon)
            regionName = result.name
            regionQuery = ""
            // Fit map to the boundary bounding box
            let b = result.bbox
            let center = CLLocationCoordinate2D(
                latitude:  (b.minLat + b.maxLat) / 2,
                longitude: (b.minLng + b.maxLng) / 2
            )
            let span = MKCoordinateSpan(
                latitudeDelta:  (b.maxLat - b.minLat) * 1.15,
                longitudeDelta: (b.maxLng - b.minLng) * 1.15
            )
            mapController.setRegion(MKCoordinateRegion(center: center, span: span), animated: true)
        } catch {
            searchError = error.localizedDescription
        }
        isRegionSearching = false
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
        let active: [JapanBoundaryService.BoundaryData] = (showPrefectures ? prefectureBoundaries : [])
            + (showMunicipalities ? municipalityBoundaries : [])
        for (idx, boundary) in active.enumerated() {
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
        if rightPanelTab == .google && searchText.isEmpty { return }

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
}

// MARK: - Supporting Views

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
    case ai, google, flickr, wikimedia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ai:        "AI"
        case .google:    "Google"
        case .flickr:    "Flickr"
        case .wikimedia: "Wiki"
        }
    }

    var icon: String {
        switch self {
        case .ai:        "sparkles"
        case .google:    "map"
        case .flickr:    "camera"
        case .wikimedia: "globe"
        }
    }

    var placeholder: String {
        switch self {
        case .ai:        ""
        case .google:    "Search Google Maps…"
        case .flickr:    "Search Flickr photos…"
        case .wikimedia: "Search Wikimedia Commons…"
        }
    }

    var emptyHint: String {
        switch self {
        case .ai:        "Ask AI Scout for locations"
        case .google:    "Search Google Maps above"
        case .flickr:    "Search for geotagged Flickr photos"
        case .wikimedia: "Search for geotagged Commons photos"
        }
    }

    var emptyIcon: String {
        switch self {
        case .ai:        "sparkles"
        case .google:    "mappin.slash"
        case .flickr:    "camera"
        case .wikimedia: "globe"
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
        .onAppear {
            NSApp.windows.forEach { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
            }
        }
}
#endif
