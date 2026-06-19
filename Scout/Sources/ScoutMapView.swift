import SwiftUI
import MapKit
import ScoutKit
import CoreVideo

// MARK: - Imperative controller

/// Lets SwiftUI issue commands to the underlying MKMapView without binding
/// the region (which would create feedback loops on every camera change).
@MainActor
final class ScoutMapController: ObservableObject {
    weak var mapView: MKMapView?

    func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        mapView?.setRegion(region, animated: animated)
    }

    func center(on coordinate: CLLocationCoordinate2D, meters: Double = 3000, animated: Bool) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters)
        setRegion(region, animated: animated)
    }

    /// Frames all given coordinates with padding.
    func fit(_ coordinates: [CLLocationCoordinate2D], padding: Double = 0.2, animated: Bool = true) {
        guard !coordinates.isEmpty else { return }
        let lats = coordinates.map(\.latitude)
        let lngs = coordinates.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLng = lngs.min()!, maxLng = lngs.max()!
        let span = MKCoordinateSpan(
            latitudeDelta:  max((maxLat - minLat) * (1 + padding), 0.01),
            longitudeDelta: max((maxLng - minLng) * (1 + padding), 0.01)
        )
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        setRegion(MKCoordinateRegion(center: center, span: span), animated: animated)
    }
}

// MARK: - Annotation

final class LocationAnnotation: NSObject, MKAnnotation {
    let location: ScoutLocation
    var coordinate: CLLocationCoordinate2D { location.coordinate }
    var title: String? { location.name }
    var subtitle: String? { location.description.isEmpty ? nil : location.description }
    init(_ location: ScoutLocation) { self.location = location }
}

// MARK: - Scroll-to-zoom map subclass (macOS)

#if os(macOS)
final class ZoomableMapView: MKMapView {
    var scrollZoomEnabled = false

    // CVDisplayLink fires vsync-aligned at the display's native refresh rate
    // (60 or 120 Hz). A flag prevents queuing multiple main-thread dispatches
    // if main falls behind.
    private var cvLink: CVDisplayLink?
    private var pendingFactor: Double = 1.0
    private var frameHasActivity = false
    private var mainDispatchPending = false  // accessed only on main thread

    override func scrollWheel(with event: NSEvent) {
        guard scrollZoomEnabled, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }

        // Accumulate multiplicative factor; cursor position is read fresh each
        // display-link tick via NSEvent.mouseLocation so no stale point stored.
        pendingFactor *= pow(2.0, -event.scrollingDeltaY * 0.006)
        frameHasActivity = true

        if cvLink == nil {
            var link: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&link)
            if let link {
                CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                    guard let self else { return kCVReturnSuccess }
                    // Skip if the previous frame hasn't been applied yet.
                    guard !self.mainDispatchPending else { return kCVReturnSuccess }
                    self.mainDispatchPending = true
                    DispatchQueue.main.async { self.applyPendingZoom() }
                    return kCVReturnSuccess
                }
                CVDisplayLinkStart(link)
                cvLink = link
            }
        }
    }

    private func applyPendingZoom() {
        defer { mainDispatchPending = false }

        guard frameHasActivity else {
            if let link = cvLink { CVDisplayLinkStop(link) }
            cvLink = nil
            pendingFactor = 1.0
            return
        }

        let factor = pendingFactor
        pendingFactor = 1.0
        frameHasActivity = false

        // Get the live cursor coordinate using MapKit's own projection —
        // no axis-direction assumptions needed.
        guard let window else { return }
        let screenPt = NSEvent.mouseLocation
        let windowPt = window.convertPoint(fromScreen: screenPt)
        let viewPt   = convert(windowPt, from: nil)
        let cursor   = convert(viewPt, toCoordinateFrom: self)

        let current = region
        let newLatDelta = min(max(current.span.latitudeDelta  * factor, 0.0005), 160)
        let newLngDelta = min(max(current.span.longitudeDelta * factor, 0.0005), 160)

        // Fractional position of cursor within the current span (coordinate-system agnostic).
        // Keep that fraction constant → cursor geographic point stays under the cursor.
        let latFrac = (cursor.latitude  - current.center.latitude)  / current.span.latitudeDelta
        let lngFrac = (cursor.longitude - current.center.longitude) / current.span.longitudeDelta

        let newLat = cursor.latitude  - latFrac * newLatDelta
        let newLng = cursor.longitude - lngFrac * newLngDelta

        setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: newLat, longitude: newLng),
            span: MKCoordinateSpan(latitudeDelta: newLatDelta, longitudeDelta: newLngDelta)
        ), animated: false)
    }

    deinit { if let link = cvLink { CVDisplayLinkStop(link) } }
}
#endif

// MARK: - macOS location tracking button

#if os(macOS)
final class LocationTrackingButton: NSView {
    private weak var mapView: MKMapView?
    private let button = NSButton()

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init(frame: CGRect(origin: .zero, size: CGSize(width: 44, height: 44)))

        // Frosted-glass background matching the built-in map controls
        let fx = NSVisualEffectView(frame: bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 8
        fx.autoresizingMask = [.width, .height]
        addSubview(fx)

        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.target = self
        button.action = #selector(tapped)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        refreshIcon()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        guard let map = mapView else { return }
        let next: MKUserTrackingMode = map.userTrackingMode == .none ? .follow : .none
        map.setUserTrackingMode(next, animated: true)
        refreshIcon()
    }

    private func refreshIcon() {
        let tracking = mapView?.userTrackingMode != .none
        let cfg = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        button.image = NSImage(systemSymbolName: tracking ? "location.fill" : "location",
                               accessibilityDescription: "My location")?
            .withSymbolConfiguration(cfg)
        button.contentTintColor = tracking ? .controlAccentColor : .secondaryLabelColor
    }
}
#endif

// MARK: - Representable

struct ScoutMapView {
    @Binding var selection: ScoutLocation?
    var locations: [ScoutLocation]
    var scrollToZoom: Bool
    var initialRegion: MKCoordinateRegion?
    var controller: ScoutMapController
    var onRegionEnd: (MKCoordinateRegion) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeMap(context: Context) -> MKMapView {
        #if os(macOS)
        let map = ZoomableMapView()
        map.showsZoomControls = true
        map.showsPitchControl = true
        #else
        let map = MKMapView()
        #endif
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        #if os(macOS)
        map.showsScale = true
        #endif

        if let initialRegion {
            map.setRegion(initialRegion, animated: false)
        }

        #if os(macOS)
        let trackingButton = LocationTrackingButton(mapView: map)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(trackingButton)
        #else
        let trackingButton = MKUserTrackingButton(mapView: map)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(trackingButton)
        #endif
        NSLayoutConstraintCompat.pin(trackingButton, toTopTrailingOf: map)

        Task { @MainActor in controller.mapView = map }
        return map
    }

    private func updateMap(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        #if os(macOS)
        (map as? ZoomableMapView)?.scrollZoomEnabled = scrollToZoom
        #endif
        context.coordinator.syncAnnotations(map, locations: locations)
        context.coordinator.syncSelection(map, selection: selection)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ScoutMapView
        init(_ parent: ScoutMapView) { self.parent = parent }

        func syncAnnotations(_ map: MKMapView, locations: [ScoutLocation]) {
            let current = map.annotations.compactMap { $0 as? LocationAnnotation }
            let currentIDs = Set(current.map { $0.location.id })
            let newIDs = Set(locations.map(\.id))
            guard currentIDs != newIDs else { return }
            map.removeAnnotations(current)
            map.addAnnotations(locations.map(LocationAnnotation.init))
        }

        func syncSelection(_ map: MKMapView, selection: ScoutLocation?) {
            let selected = map.selectedAnnotations.compactMap { $0 as? LocationAnnotation }.first
            guard selected?.location.id != selection?.id else { return }

            if let selection,
               let annotation = map.annotations
                   .compactMap({ $0 as? LocationAnnotation })
                   .first(where: { $0.location.id == selection.id }) {
                map.selectAnnotation(annotation, animated: true)
            } else if selection == nil, let current = map.selectedAnnotations.first {
                map.deselectAnnotation(current, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onRegionEnd(mapView.region)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let annotation = view.annotation as? LocationAnnotation {
                parent.selection = annotation.location
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is LocationAnnotation else { return nil } // keep default user-location dot
            let id = "scoutMarker"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.canShowCallout = true
            #if os(macOS)
            view.markerTintColor = .systemOrange
            view.glyphImage = NSImage(systemSymbolName: "film.fill", accessibilityDescription: nil)
            #else
            view.markerTintColor = .systemOrange
            view.glyphImage = UIImage(systemName: "film.fill")
            #endif
            return view
        }
    }
}

#if os(macOS)
extension ScoutMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateNSView(_ nsView: MKMapView, context: Context) { updateMap(nsView, context: context) }
}
#else
extension ScoutMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(context: context) }
    func updateUIView(_ uiView: MKMapView, context: Context) { updateMap(uiView, context: context) }
}
#endif

// MARK: - Cross-platform constraint helper

enum NSLayoutConstraintCompat {
    static func pin(_ subview: PlatformView, toTopTrailingOf parent: PlatformView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            subview.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            subview.topAnchor.constraint(equalTo: parent.topAnchor, constant: 16),
            subview.widthAnchor.constraint(equalToConstant: 44),
            subview.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
}

#if os(macOS)
typealias PlatformView = NSView
#else
typealias PlatformView = UIView
#endif
