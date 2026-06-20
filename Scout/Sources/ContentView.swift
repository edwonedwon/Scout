import SwiftUI
import MapKit
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

    @AppStorage("search.mode") private var searchMode: SearchMode = .google

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isAISearching = false
    @State private var locations: [ScoutLocation] = []
    @State private var selectedLocation: ScoutLocation?
    @State private var searchError: String?
    @State private var didInitialCenter = false
    @State private var chatMessages: [ChatMessage] = []

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
            googlePanel
                .frame(width: 280)
            Divider()
            mapView
            Divider()
            aiPanel
                .frame(width: 300)
        }
        .ignoresSafeArea()
        .onAppear {
            #if !DEBUG
            locationManager.requestIfNeeded()
            #endif
            centerOnUserIfNeeded()
        }
        .onChange(of: locationManager.currentLocation?.latitude) { _, _ in
            centerOnUserIfNeeded()
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

    // MARK: - Left search panel

    private var googlePanel: some View {
        VStack(spacing: 0) {
            panelHeader("Locations") {
                if isSearching && !isAISearching {
                    ProgressView().controlSize(.small)
                }
            }

            // Source toggle
            Picker("Search source", selection: $searchMode) {
                ForEach(SearchMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .onChange(of: searchMode) { _, _ in locations = []; selectedLocation = nil }

            // Search bar
            HStack {
                TextField(searchMode.placeholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await runSearch() } }
                Button { Task { await runSearch() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled(searchText.isEmpty || isSearching)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            List(locations, selection: $selectedLocation) { location in
                LocationRow(location: location)
                    .tag(location)
            }
            .overlay {
                if locations.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: searchMode.emptyIcon,
                        description: Text(searchMode.emptyHint)
                    )
                }
            }
        }
    }

    // MARK: - AI Scout panel (right)

    private var aiPanel: some View {
        VStack(spacing: 0) {
            panelHeader("AI Scout") {
                EmptyView()
            }
            Divider()
            AIChatView(
                messages: $chatMessages,
                isSearching: isAISearching,
                onSend: { text, model, thinking in
                    Task { await runAISearch(query: text, model: model, extendedThinking: thinking) }
                }
            )
        }
    }

    private func panelHeader<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Map

    private var mapView: some View {
        ScoutMapView(
            selection: $selectedLocation,
            locations: locations,
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
            onPolygonComplete: { coords in searchArea.setPolygon(coords) }
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
        .overlay(alignment: .bottomLeading) {
            DebugPanelOverlay()
                .padding()
        }
        .overlay(alignment: .bottomTrailing) {
            lassoControls
        }
        .overlay {
            if photoViewer.isVisible {
                PhotoViewerOverlay()
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: photoViewer.isVisible)
            }
        }
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
        switch searchMode {
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
        guard !searchText.isEmpty else { return }
        isSearching = true
        searchError = nil
        locations = []
        do {
            dlog("Wikimedia search: \"\(searchText)\"", level: .info, tag: "Search")
            let region: GooglePlacesService.MapRegion? =
                searchArea.mapRegion ??
                (hasSavedRegion ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta) : nil)
            var results = try await WikimediaService.shared.search(query: searchText, region: region)
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
        var coords = locations.map(\.coordinate)
        if let userCoord = locationManager.currentLocation {
            coords.append(userCoord)
        }
        mapController.fit(coords, animated: true)
    }
}

// MARK: - Supporting Views

struct LocationRow: View {
    let location: ScoutLocation

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

// MARK: - Search mode

enum SearchMode: String, CaseIterable, Identifiable {
    case google
    case flickr
    case wikimedia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .google:    "Google"
        case .flickr:    "Flickr"
        case .wikimedia: "Wiki"
        }
    }

    var icon: String {
        switch self {
        case .google:    "map"
        case .flickr:    "camera"
        case .wikimedia: "globe"
        }
    }

    var placeholder: String {
        switch self {
        case .google:    "Search Google Maps…"
        case .flickr:    "Search Flickr photos…"
        case .wikimedia: "Search Wikimedia Commons…"
        }
    }

    var emptyHint: String {
        switch self {
        case .google:    "Search above or use AI Scout"
        case .flickr:    "Search for geotagged Flickr photos"
        case .wikimedia: "Search for geotagged Commons photos"
        }
    }

    var emptyIcon: String {
        switch self {
        case .google:    "mappin.slash"
        case .flickr:    "camera"
        case .wikimedia: "globe"
        }
    }
}
