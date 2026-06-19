import SwiftUI
import MapKit
import ScoutKit

enum SearchMode: String, CaseIterable {
    case googleMaps = "Google Maps"
    case aiScout = "AI Scout"

    var placeholder: String {
        switch self {
        case .googleMaps: "Search Google Maps..."
        case .aiScout: "Describe what you're looking for..."
        }
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

    @StateObject private var mapController = ScoutMapController()

    @State private var searchText = ""
    @State private var searchMode: SearchMode = .googleMaps
    @State private var isSearching = false
    @State private var locations: [ScoutLocation] = []
    @State private var selectedLocation: ScoutLocation?
    @State private var searchError: String?
    @State private var didInitialCenter = false

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
        NavigationSplitView {
            sidebar
        } detail: {
            mapView
        }
        .navigationTitle("Scout")
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

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchBar
            locationList
        }
        .navigationTitle("Locations")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsButton
            }
        }
        #endif
    }

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(searchMode.placeholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await runSearch() } }

                Button {
                    Task { await runSearch() }
                } label: {
                    if isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(searchText.isEmpty || isSearching)
            }

            Picker("Search Mode", selection: $searchMode) {
                ForEach(SearchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: searchMode) { _, _ in searchText = "" }
        }
        .padding()
    }

    private var locationList: some View {
        List(locations, selection: $selectedLocation) { location in
            LocationRow(location: location)
                .tag(location)
        }
        .overlay {
            if locations.isEmpty && !isSearching {
                ContentUnavailableView(
                    "No Locations",
                    systemImage: "mappin.slash",
                    description: Text("Search for locations above to get started.")
                )
            }
        }
    }

    private var settingsButton: some View {
        NavigationLink {
            SettingsView()
        } label: {
            Image(systemName: "gear")
        }
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
            }
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
    }

    // MARK: - Search

    @MainActor
    private func runSearch() async {
        guard !searchText.isEmpty else { return }
        isSearching = true
        searchError = nil
        locations = []

        do {
            switch searchMode {
            case .googleMaps:
                dlog("Starting Google Maps search: \"\(searchText)\"", level: .info, tag: "Search")
                let region: GooglePlacesService.MapRegion? = hasSavedRegion
                    ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta)
                    : nil
                let results = try await GooglePlacesService.shared.search(query: searchText, region: region)
                locations = results
                selectedLocation = nil
                dlog("Google Maps returned \(results.count) results", level: .success, tag: "Search")
            case .aiScout:
                try await ClaudeService.shared.searchLocations(query: searchText) { location in
                    Task { @MainActor in
                        self.locations.append(location)
                    }
                }
            }
        } catch {
            searchError = error.localizedDescription
        }

        isSearching = false
        if !locations.isEmpty {
            fitMapToResults()
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
