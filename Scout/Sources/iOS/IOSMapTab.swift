// IOSMapTab.swift — native SwiftUI map for iOS, wired to real pins.

#if os(iOS)
import SwiftUI
import MapKit
import CoreLocation
import ScoutKit

struct IOSMapTab: View {
    @ObservedObject var project: ProjectVM
    @Binding var visibleListIDs: Set<UUID>
    @Binding var focusPin: PinVM?
    let link: MapGridLink
    @Binding var focusRequest: MapFocusRequest?
    let onMenu: () -> Void

    @State private var selectedPin: PinVM?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapStyleChoice: MapStyleChoice = .standard
    @State private var showPhotos = false
    // The current visible span, used to size cluster cells. Updated as the camera moves.
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    @Namespace private var mapScope
    @StateObject private var location = MapLocationProvider()
    @State private var focusUserPending = false

    // Rotation is allowed (so the compass can reset it and deliberate turns work), but the camera's
    // onEnd handler snaps small accidental twists back to north — so a stray rotation while
    // pinch-zooming self-corrects, while a larger intentional turn sticks.
    private let interaction: MapInteractionModes = [.pan, .zoom, .rotate]
    private let northSnapDegrees: Double = 12

    enum MapStyleChoice: String, CaseIterable, Identifiable {
        case standard, satellite, hybrid
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .standard: "map"
            case .satellite: "globe.americas.fill"
            case .hybrid: "map.fill"
            }
        }
        var style: _MapKit_SwiftUI.MapStyle {
            switch self {
            case .standard: .standard
            case .satellite: .imagery
            case .hybrid: .hybrid
            }
        }
    }

    private var visiblePins: [PinVM] {
        project.visiblePins(visibleListIDs).filter { $0.latitude != 0 || $0.longitude != 0 }
    }

    /// Grid-bucket the visible pins by the current zoom so the map draws a few dozen markers, not
    /// hundreds (which froze it). Cells shrink as you zoom in, so clusters split apart naturally.
    private var clusters: [MapCluster] {
        let pins = visiblePins
        guard pins.count > 1 else { return pins.map { MapCluster(id: $0.id, coordinate: $0.coordinate, pins: [$0]) } }
        let cellLat = max(visibleSpan.latitudeDelta / 18, 0.00015)
        let cellLng = max(visibleSpan.longitudeDelta / 18, 0.00015)
        var buckets: [String: [PinVM]] = [:]
        for p in pins {
            let key = "\(Int((p.latitude / cellLat).rounded(.down)))_\(Int((p.longitude / cellLng).rounded(.down)))"
            buckets[key, default: []].append(p)
        }
        return buckets.map { key, ps in
            if ps.count == 1 { return MapCluster(id: ps[0].id, coordinate: ps[0].coordinate, pins: ps) }
            let lat = ps.reduce(0) { $0 + $1.latitude } / Double(ps.count)
            let lng = ps.reduce(0) { $0 + $1.longitude } / Double(ps.count)
            return MapCluster(id: key, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng), pins: ps)
        }
    }

    private var defaultRegion: MKCoordinateRegion {
        let center = project.allMapPins.first.map(\.coordinate)
            ?? CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))
    }

    /// Tapping a cluster zooms to fit its pins (or just tightens if they're stacked).
    private func zoomInto(_ cluster: MapCluster) {
        let lats = cluster.pins.map(\.latitude), lngs = cluster.pins.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((lats.max()! - lats.min()!) * 1.4, visibleSpan.latitudeDelta / 3),
            longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.4, visibleSpan.longitudeDelta / 3))
        withAnimation(.easeInOut(duration: 0.4)) { cameraPosition = .region(MKCoordinateRegion(center: center, span: span)) }
        visibleSpan = span
    }

    /// Snap back to north when the heading is only slightly off (an accidental twist), leaving a
    /// deliberate larger rotation alone. Keeps the map north-facing without fully disabling rotation.
    private func snapNorthIfNudged(_ camera: MapCamera) {
        let h = camera.heading
        let offNorth = min(h, 360 - h)   // degrees away from north, 0...180
        guard offNorth >= 0.5, offNorth < northSnapDegrees else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            cameraPosition = .camera(MapCamera(centerCoordinate: camera.centerCoordinate,
                                               distance: camera.distance, heading: 0, pitch: camera.pitch))
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition, interactionModes: interaction, scope: mapScope) {
                UserAnnotation()
                ForEach(clusters) { cluster in
                    Annotation(cluster.pins.first?.name ?? "", coordinate: cluster.coordinate) {
                        if let pin = cluster.single {
                            Group { showPhotos ? AnyView(IOSPhotoMarker(pin: pin)) : AnyView(IOSPinDot(color: pin.displayColor)) }
                                .onTapGesture { selectedPin = pin }
                        } else {
                            ClusterBadge(count: cluster.pins.count)
                                .onTapGesture { zoomInto(cluster) }
                        }
                    }
                }
            }
            .mapStyle(mapStyleChoice.style)
            .ignoresSafeArea()
            .onAppear { cameraPosition = .region(defaultRegion); visibleSpan = defaultRegion.span }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                visibleSpan = ctx.region.span
                link.mapCenter = ctx.region.center   // remembered for the Photos tab to scroll to
                snapNorthIfNudged(ctx.camera)
            }
            // Photos → Map: zoom to fit the photos the grid was showing.
            .onChange(of: focusRequest) { _, req in
                guard let req else { return }
                withAnimation(.easeInOut(duration: 0.5)) { cameraPosition = .region(req.region) }
                visibleSpan = req.span
                focusRequest = nil
            }
            // When the locate button gets a fresh fix, zoom in on the user.
            .onChange(of: location.lastFixID) { _, _ in
                guard focusUserPending, let c = location.lastLocation else { return }
                focusUserPending = false
                let span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                withAnimation(.easeInOut(duration: 0.45)) {
                    cameraPosition = .region(MKCoordinateRegion(center: c, span: span))
                }
                visibleSpan = span
            }
            // Compass (reset-to-north) + zoom-to-my-location, stacked above the tab bar.
            .overlay(alignment: .bottomTrailing) {
                VStack(spacing: 12) {
                    MapCompass(scope: mapScope)
                        .mapControlVisibility(.visible)
                    Button {
                        focusUserPending = true
                        location.requestOneShot()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.trailing, 12)
                .padding(.bottom, 28)
            }
            .onChange(of: focusPin) { _, pin in
                guard let pin else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: pin.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    ))
                }
                selectedPin = pin
                focusPin = nil
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onMenu) {
                        Image(systemName: "line.3.horizontal")
                            .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            .frame(width: 36, height: 36).background(.regularMaterial, in: Circle())
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("Search locations…").foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                    Menu {
                        Picker("Map Type", selection: $mapStyleChoice) {
                            ForEach(MapStyleChoice.allCases) { choice in
                                Label(choice.label, systemImage: choice.icon).tag(choice)
                            }
                        }
                        Picker("Show", selection: $showPhotos) {
                            Label("Pins", systemImage: "mappin").tag(false)
                            Label("Photos", systemImage: "photo").tag(true)
                        }
                    } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            .frame(width: 36, height: 36).background(.regularMaterial, in: Circle())
                    }
                }
                // Photo-download progress sits just under the search bar, only while downloading.
                PhotoSyncBar()
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
        .sheet(item: $selectedPin) { pin in
            IOSPinCalloutSheet(pin: pin)
                .presentationDetents([.height(320), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }
    }
}

/// A grid bucket of nearby pins at the current zoom (1 pin = shown directly, >1 = a count badge).
struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let pins: [PinVM]
    var single: PinVM? { pins.count == 1 ? pins[0] : nil }
}

struct ClusterBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.caption.bold()).foregroundStyle(.white)
            .frame(minWidth: 30, minHeight: 30).padding(3)
            .background(Circle().fill(.orange))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}

struct IOSPinDot: View {
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 28, height: 28)
            Circle().fill(.white).frame(width: 12, height: 12)
        }
        .shadow(radius: 2)
    }
}

struct IOSPhotoMarker: View {
    let pin: PinVM
    var body: some View {
        IOSPinThumb(pin: pin, targetPixelSize: 96, cornerRadius: 8)
            .frame(width: 48, height: 48)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2.5) }
            .overlay(alignment: .bottom) {
                Circle().fill(pin.displayColor).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5)).offset(y: 5)
            }
            .shadow(radius: 3)
    }
}

/// One-shot location provider for the map's "zoom to me" button. Prompts for permission on first
/// use and publishes each fix; `lastFixID` increments per fix so the view can react even when the
/// coordinate is unchanged.
final class MapLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var lastLocation: CLLocationCoordinate2D?
    @Published private(set) var lastFixID = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Ask for a single fix, prompting for permission the first time.
    func requestOneShot() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()   // the fix follows on grant
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break   // denied/restricted — nothing to do
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let c = locs.last?.coordinate else { return }
        lastLocation = c
        lastFixID += 1
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        default: break
        }
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

struct IOSPinCalloutSheet: View {
    @ObservedObject var pin: PinVM

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSPinThumb(pin: pin, targetPixelSize: 256, cornerRadius: 10)
                .frame(height: 130).frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(pin.displayColor).frame(width: 10, height: 10)
                    Text(pin.name).font(.headline)
                    Spacer()
                }
                if !pin.notes.isEmpty {
                    Text(pin.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Divider()
                HStack(spacing: 12) {
                    Label(String(format: "%.4f, %.4f", pin.latitude, pin.longitude), systemImage: "location.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    if let d = pin.dateTaken {
                        Label(d.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }
}
#endif
