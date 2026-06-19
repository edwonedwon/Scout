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

    @State private var searchText = ""
    @State private var searchMode: SearchMode = .googleMaps
    @State private var isSearching = false
    @State private var locations: [ScoutLocation] = []
    @State private var selectedLocation: ScoutLocation?
    @State private var searchError: String?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var liveCenter: CLLocationCoordinate2D = .init(latitude: 0, longitude: 0)
    @State private var liveSpan: MKCoordinateSpan = .init(latitudeDelta: 0.1, longitudeDelta: 0.1)

    private var hasSavedRegion: Bool {
        !savedLat.isNaN && !savedLng.isNaN
    }

    private var initialCameraPosition: MapCameraPosition {
        // Always open at current location if permitted — you're out scouting
        if locationManager.isAuthorized {
            return .userLocation(fallback: hasSavedRegion ? .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: savedLat, longitude: savedLng),
                span: MKCoordinateSpan(latitudeDelta: savedLatDelta, longitudeDelta: savedLngDelta)
            )) : .automatic)
        }
        // No permission — restore last known region or world view
        if hasSavedRegion {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: savedLat, longitude: savedLng),
                span: MKCoordinateSpan(latitudeDelta: savedLatDelta, longitudeDelta: savedLngDelta)
            ))
        }
        return .automatic
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mapView
        }
        .navigationTitle("Scout")
        .onAppear {
            cameraPosition = initialCameraPosition
            #if !DEBUG
            locationManager.requestIfNeeded()
            #endif
        }
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
        Map(position: $cameraPosition, selection: $selectedLocation) {
            UserAnnotation()
            ForEach(locations) { location in
                Marker(location.name, coordinate: location.coordinate)
                    .tag(location)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        #if os(macOS)
        .scrollZoom(enabled: scrollToZoom) { multiplier, cursor in
            let newLatDelta = max(min(liveSpan.latitudeDelta  * multiplier, 180), 0.001)
            let newLngDelta = max(min(liveSpan.longitudeDelta * multiplier, 360), 0.001)

            // Shift center so the point under the cursor stays fixed
            // NSView y is bottom-up so fy > 0 = north, fx > 0 = east
            let newLat = liveCenter.latitude  + cursor.y * liveSpan.latitudeDelta  * (1 - multiplier)
            let newLng = liveCenter.longitude + cursor.x * liveSpan.longitudeDelta * (1 - multiplier)

            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                cameraPosition = .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: newLat, longitude: newLng),
                    span: MKCoordinateSpan(latitudeDelta: newLatDelta, longitudeDelta: newLngDelta)
                ))
            }
        }
        #endif
        .mapControls {
            MapCompass()
            MapScaleView()
            MapUserLocationButton()
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if let error = searchError {
                    Text(error)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
                DebugPanelOverlay()
            }
            .padding()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            liveCenter = context.region.center
            liveSpan   = context.region.span
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            savedLat      = region.center.latitude
            savedLng      = region.center.longitude
            savedLatDelta = region.span.latitudeDelta
            savedLngDelta = region.span.longitudeDelta
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
        guard !coords.isEmpty else { return }

        let lats = coords.map(\.latitude)
        let lngs = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!

        let padding = 0.2
        let latDelta = max((maxLat - minLat) * (1 + padding), 0.01)
        let lngDelta = max((maxLng - minLng) * (1 + padding), 0.01)

        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (minLat + maxLat) / 2,
                    longitude: (minLng + maxLng) / 2
                ),
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta)
            ))
        }
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
