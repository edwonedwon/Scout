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
    @AppStorage("map.lat")      private var savedLat:      Double = .nan
    @AppStorage("map.lng")      private var savedLng:      Double = .nan
    @AppStorage("map.latDelta") private var savedLatDelta: Double = .nan
    @AppStorage("map.lngDelta") private var savedLngDelta: Double = .nan

    @State private var searchText = ""
    @State private var searchMode: SearchMode = .googleMaps
    @State private var isSearching = false
    @State private var locations: [ScoutLocation] = []
    @State private var selectedLocation: ScoutLocation?
    @State private var searchError: String?
    @State private var cameraPosition: MapCameraPosition = .automatic

    private var hasSavedRegion: Bool {
        !savedLat.isNaN && !savedLng.isNaN
    }

    private var initialCameraPosition: MapCameraPosition {
        if hasSavedRegion {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: savedLat, longitude: savedLng),
                span: MKCoordinateSpan(latitudeDelta: savedLatDelta, longitudeDelta: savedLngDelta)
            ))
        }
        return .userLocation(fallback: .automatic)
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
            locationManager.requestPermission()
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
            ForEach(locations) { location in
                Marker(location.name, coordinate: location.coordinate)
                    .tag(location)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
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
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            savedLat      = region.center.latitude
            savedLng      = region.center.longitude
            savedLatDelta = region.span.latitudeDelta
            savedLngDelta = region.span.longitudeDelta
        }
        .onChange(of: selectedLocation) { _, location in
            if let location {
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))
                }
            }
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
                let results = try await GooglePlacesService.shared.search(query: searchText)
                locations = results
                selectedLocation = results.first
                dlog("Google Maps returned \(results.count) results", level: .success, tag: "Search")
            case .aiScout:
                try await ClaudeService.shared.searchLocations(query: searchText) { location in
                    Task { @MainActor in
                        self.locations.append(location)
                        if self.locations.count == 1 {
                            self.selectedLocation = location
                        }
                    }
                }
            }
        } catch {
            searchError = error.localizedDescription
        }

        isSearching = false
    }
}

// MARK: - Supporting Views

struct LocationRow: View {
    let location: ScoutLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(location.name)
                .font(.headline)
            if !location.description.isEmpty {
                Text(location.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
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
        .padding(.vertical, 2)
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
