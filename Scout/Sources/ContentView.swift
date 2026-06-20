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
    @AppStorage("wikimedia.limit") private var wikiLimit: Double = 50

    private var cyclingProvider: CyclingTileProvider? {
        get { CyclingTileProvider(rawValue: cyclingProviderRaw) }
        set { cyclingProviderRaw = newValue?.rawValue ?? "" }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocationListData.createdAt) private var allLists: [LocationListData]

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
    @State private var activeList: LocationListData?

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
                ProjectsPanel(activeList: $activeList)
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
        .onAppear {
            #if !DEBUG
            locationManager.requestIfNeeded()
            #endif
            centerOnUserIfNeeded()
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
                        if rightPanelTab == .wikimedia || !searchText.isEmpty {
                            Task { await runSearch() }
                        }
                    }
                Button { Task { await runSearch() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled((searchText.isEmpty && rightPanelTab != .wikimedia) || isSearching)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, rightPanelTab == .wikimedia ? 4 : 8)

            if rightPanelTab == .wikimedia {
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
                    Slider(value: $wikiLimit, in: 10...500, step: 10)
                    Text("\(Int(wikiLimit))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            Divider()

            List(locations, selection: $selectedLocation) { location in
                LocationRow(location: location, availableLists: allLists) { list in
                    saveToList(location, list)
                }
                .draggable(location)
                .tag(location)
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
            PhotoGridView(locations: locations)
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
                panelToggleButton(
                    icon: showRightPanel ? "sidebar.right" : "rectangle.rightthird.inset.filled",
                    action: { showRightPanel.toggle() }
                )
            }
            .padding(.top, 14)
            .padding(.horizontal, 8)
        }
        .overlay {
            if photoViewer.isVisible {
                PhotoViewerOverlay()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: photoViewer.isVisible)
            }
        }
    }

    private func panelToggleButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
    }

    private var projectPins: [(ScoutLocation, String)] {
        guard let list = activeList else { return [] }
        return list.pins.map { ($0.asScoutLocation(), list.colorHex) }
    }

    private func saveToList(_ location: ScoutLocation, _ list: LocationListData) {
        let pin = PinnedLocationData(from: location)
        pin.list = list
        list.pins.append(pin)
        modelContext.insert(pin)
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
            cyclingProvider: cyclingProvider,
            availableLists: allLists,
            onSaveToList: saveToList
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
                cyclingControls
                if cyclingProvider == .cyclOSM {
                    cyclOSMLegend
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: cyclingProvider == .cyclOSM)
        }
        .overlay(alignment: .leading) {
            lassoControls
        }
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

    private var cyclingControls: some View {
        Menu {
            ForEach(CyclingTileProvider.allCases) { provider in
                Button {
                    if cyclingProvider == provider {
                        cyclingProviderRaw = ""
                    } else {
                        cyclingProviderRaw = provider.rawValue
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(provider.displayName)
                            Text(provider.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        if cyclingProvider == provider {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if cyclingProvider != nil {
                Divider()
                Button("Turn Off", role: .destructive) {
                    cyclingProviderRaw = ""
                }
            }
        } label: {
            Image(systemName: "bicycle")
                .font(.title2)
                .foregroundStyle(cyclingProvider != nil ? .blue : .primary)
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(16)
        .help(cyclingProvider.map { "Cycling: \($0.displayName)" } ?? "Show cycling map")
    }

    private var lassoControls: some View {
        VStack(spacing: 8) {
            if searchArea.isActive {
                Button(action: searchArea.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.multicolor)
                }
                .buttonStyle(.plain)
                .help("Clear search area")
                .transition(.scale.combined(with: .opacity))
            }
            Button {
                if searchArea.isDrawing {
                    searchArea.isDrawing = false
                } else {
                    searchArea.isDrawing = true
                }
            } label: {
                Image(systemName: searchArea.isDrawing ? "xmark.circle.fill" : "lasso")
                    .font(.title2)
                    .foregroundStyle(searchArea.isDrawing ? .red : searchArea.isActive ? .blue : .primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .help(searchArea.isDrawing ? "Cancel" : searchArea.isActive ? "Redraw search area" : "Draw search area")
        }
        .padding(16)
        .animation(.spring(duration: 0.2), value: searchArea.isActive)
    }

    // MARK: - Search

    @MainActor
    private func runSearch() async {
        switch rightPanelTab {
        case .ai:        break
        case .google:    await runGoogleSearch()
        case .flickr:    await runFlickrSearch()
        case .wikimedia: await runWikimediaSearch()
        }
    }

    @MainActor
    private func runGoogleSearch() async {
        guard !searchText.isEmpty else { return }
        isSearching = true
        searchError = nil
        locations = []
        do {
            dlog("Google Maps search: \"\(searchText)\"", level: .info, tag: "Search")
            let region: GooglePlacesService.MapRegion? =
                searchArea.mapRegion ??
                (hasSavedRegion ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta) : nil)
            var results = try await GooglePlacesService.shared.search(query: searchText, region: region)
            if searchArea.isActive { results = results.filter { searchArea.contains($0.coordinate) } }
            locations = results
            selectedLocation = nil
            dlog("Google Maps returned \(results.count) results", level: .success, tag: "Search")
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
        if !locations.isEmpty { fitMapToResults() }
    }

    @MainActor
    private func runFlickrSearch() async {
        guard !searchText.isEmpty else { return }
        isSearching = true
        searchError = nil
        locations = []
        do {
            dlog("Flickr search: \"\(searchText)\"", level: .info, tag: "Search")
            let region: GooglePlacesService.MapRegion? =
                searchArea.mapRegion ??
                (hasSavedRegion ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta) : nil)
            var results = try await FlickrService.shared.search(query: searchText, region: region)
            if searchArea.isActive { results = results.filter { searchArea.contains($0.coordinate) } }
            locations = results
            selectedLocation = nil
            dlog("Flickr returned \(results.count) results", level: .success, tag: "Search")
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
        if !locations.isEmpty { fitMapToResults() }
    }

    @MainActor
    private func runWikimediaSearch() async {
        isSearching = true
        searchError = nil
        locations = []
        do {
            dlog("Wikimedia search: \"\(searchText)\"", level: .info, tag: "Search")
            let region: GooglePlacesService.MapRegion? =
                searchArea.mapRegion ??
                (hasSavedRegion ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta) : nil)
            var results = try await WikimediaService.shared.search(query: searchText, region: region, limit: Int(wikiLimit))
            if searchArea.isActive { results = results.filter { searchArea.contains($0.coordinate) } }
            locations = results
            selectedLocation = nil
            dlog("Wikimedia returned \(results.count) results", level: .success, tag: "Search")
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
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

struct LocationRow: View {
    let location: ScoutLocation
    var availableLists: [LocationListData] = []
    var onSaveToList: ((LocationListData) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Photo filmstrip
            if !location.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(location.images) { image in
                            if let url = image.url {
                                AsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let img):
                                        img.resizable()
                                            .scaledToFill()
                                    case .failure:
                                        Color.secondary.opacity(0.2)
                                    default:
                                        Color.secondary.opacity(0.1)
                                            .overlay(ProgressView().controlSize(.mini))
                                    }
                                }
                                .frame(width: 100, height: 70)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 74)
                // Allow horizontal scroll without stealing list swipes
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }

            // Name + address
            Text(location.name)
                .font(.headline)
                .lineLimit(1)

            if !location.description.isEmpty {
                Text(location.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Status + Maps link
            HStack {
                Label(location.status.rawValue, systemImage: statusIcon)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
                Spacer()
                if let url = location.googleMapsURL {
                    Link(destination: url) {
                        Image(systemName: "map")
                            .font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let onSaveToList, !availableLists.isEmpty {
                Menu {
                    ForEach(availableLists) { list in
                        Button {
                            onSaveToList(list)
                        } label: {
                            Label(list.name, systemImage: "mappin.circle")
                        }
                    }
                } label: {
                    Label("Save to List", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private var statusIcon: String {
        switch location.status {
        case .scouted: "mappin.circle"
        case .shortlisted: "star.circle"
        case .approved: "checkmark.circle.fill"
        case .rejected: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch location.status {
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

// MARK: - Preview

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
