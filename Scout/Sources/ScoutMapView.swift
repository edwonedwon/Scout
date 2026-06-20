import SwiftUI
import MapKit
import ScoutKit
import CoreVideo
import Combine

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

// MARK: - Cycling tile providers

enum CyclingTileProvider: String, CaseIterable, Identifiable {
    case waymarked = "waymarked"
    case cyclOSM   = "cyclosm"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waymarked: "Waymarked Trails"
        case .cyclOSM:   "CyclOSM"
        }
    }

    var description: String {
        switch self {
        case .waymarked: "Cycling routes overlaid on Apple Maps (free)"
        case .cyclOSM:   "Full cycling-focused map (free)"
        }
    }

    var urlTemplate: String {
        switch self {
        case .waymarked: "https://tile.waymarkedtrails.org/cycling/{z}/{x}/{y}.png"
        case .cyclOSM:   "https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png"
        }
    }

    // Whether this layer replaces Apple Maps tiles entirely
    var replacesBaseMap: Bool {
        switch self {
        case .waymarked: false
        case .cyclOSM:   true
        }
    }
}

// MKTileOverlay subclass that handles {s} subdomain cycling
final class CyclingTileOverlay: MKTileOverlay {
    let provider: CyclingTileProvider
    private let subdomains = ["a", "b", "c"]

    init(provider: CyclingTileProvider) {
        self.provider = provider
        super.init(urlTemplate: nil)
        canReplaceMapContent = provider.replacesBaseMap
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        var template = provider.urlTemplate
        if template.contains("{s}") {
            let sub = subdomains[(path.x + path.y) % subdomains.count]
            template = template.replacingOccurrences(of: "{s}", with: sub)
        }
        template = template
            .replacingOccurrences(of: "{z}", with: "\(path.z)")
            .replacingOccurrences(of: "{x}", with: "\(path.x)")
            .replacingOccurrences(of: "{y}", with: "\(path.y)")
        return URL(string: template)!
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
    // With .hiddenTitleBar, macOS treats the window background as draggable.
    // Returning false here tells AppKit that clicks on the map are real interactions,
    // not window-drag attempts — otherwise the location/zoom buttons stop responding.
    override var mouseDownCanMoveWindow: Bool { false }
    var scrollZoomEnabled = false

    // MARK: - Lasso drawing

    var isDrawingMode = false {
        didSet {
            if isDrawingMode {
                NSCursor.crosshair.push()
                // MKMapView pans via gesture recognizers that run alongside the
                // responder chain — disabling them prevents panning while drawing.
                gestureRecognizers.forEach { $0.isEnabled = false }
            } else {
                NSCursor.pop()
                gestureRecognizers.forEach { $0.isEnabled = true }
                clearDrawingLayer()
                drawPoints = []
            }
        }
    }
    var onPolygonComplete: (([CLLocationCoordinate2D]) -> Void)?

    private var drawPoints: [CGPoint] = []
    private var drawingLayer: CAShapeLayer?
    private var lastAddedPoint: CGPoint = .zero
    private let pointSpacing: CGFloat = 6

    override func mouseDown(with event: NSEvent) {
        guard isDrawingMode else { super.mouseDown(with: event); return }
        wantsLayer = true
        let pt = convert(event.locationInWindow, from: nil)
        drawPoints = [pt]
        lastAddedPoint = pt
        setupDrawingLayer()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawingMode else { super.mouseDragged(with: event); return }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - lastAddedPoint.x, dy = pt.y - lastAddedPoint.y
        guard sqrt(dx*dx + dy*dy) >= pointSpacing else { return }
        lastAddedPoint = pt
        drawPoints.append(pt)
        updateDrawingLayer()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawingMode else { super.mouseUp(with: event); return }
        let coords = drawPoints.map { convert($0, toCoordinateFrom: self) }
        isDrawingMode = false   // pops cursor + clears layer
        if coords.count >= 3 { onPolygonComplete?(coords) }
    }

    private func setupDrawingLayer() {
        clearDrawingLayer()
        let sl = CAShapeLayer()
        sl.fillColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        sl.strokeColor = NSColor.systemBlue.cgColor
        sl.lineWidth = 2
        sl.lineDashPattern = [6, 4]
        sl.frame = bounds
        layer?.addSublayer(sl)
        drawingLayer = sl
    }

    private func updateDrawingLayer() {
        guard let sl = drawingLayer, drawPoints.count >= 2 else { return }
        let path = CGMutablePath()
        path.move(to: drawPoints[0])
        drawPoints.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        sl.path = path
    }

    private func clearDrawingLayer() {
        drawingLayer?.removeFromSuperlayer()
        drawingLayer = nil
    }

    // MARK: - CVDisplayLink scroll-zoom

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
    private var trackingObservation: NSKeyValueObservation?

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

        // Keep icon in sync when MapKit disables tracking after a user pan
        trackingObservation = mapView.observe(\.userTrackingMode, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }

        refreshIcon()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        trackingObservation?.invalidate()
    }

    @objc private func tapped() {
        guard let map = mapView else { return }
        let next: MKUserTrackingMode = map.userTrackingMode == .none ? .follow : .none
        map.setUserTrackingMode(next, animated: true)
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
    var isDrawingMode: Bool = false
    var searchPolygon: [CLLocationCoordinate2D]? = nil
    var onPolygonComplete: ([CLLocationCoordinate2D]) -> Void = { _ in }
    var cyclingProvider: CyclingTileProvider? = nil

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
        if let zoomable = map as? ZoomableMapView {
            zoomable.scrollZoomEnabled = scrollToZoom
            zoomable.isDrawingMode = isDrawingMode
            zoomable.onPolygonComplete = onPolygonComplete
        }
        #endif
        context.coordinator.syncAnnotations(map, locations: locations)
        context.coordinator.syncSelection(map, selection: selection)
        syncTileOverlay(map)
        syncPolygonOverlay(map)
    }

    private func syncTileOverlay(_ map: MKMapView) {
        let existing = map.overlays.compactMap { $0 as? CyclingTileOverlay }
        // Skip update if provider hasn't changed
        if let current = existing.first, current.provider == cyclingProvider { return }
        map.removeOverlays(existing)
        if let provider = cyclingProvider {
            map.addOverlay(CyclingTileOverlay(provider: provider), level: .aboveRoads)
        }
    }

    private func syncPolygonOverlay(_ map: MKMapView) {
        let existing = map.overlays.compactMap { $0 as? MKPolygon }
        map.removeOverlays(existing)
        if var coords = searchPolygon, coords.count >= 3 {
            // Add above cycling tiles so the polygon is always visible
            map.addOverlay(MKPolygon(coordinates: &coords, count: coords.count), level: .aboveLabels)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: ScoutMapView

        init(_ parent: ScoutMapView) {
            self.parent = parent
            super.init()
            #if os(macOS)
            // Close pin popover whenever the full-screen photo viewer opens
            photoViewerCancellable = PhotoViewerState.shared.$isVisible
                .sink { [weak self] isVisible in
                    guard isVisible else { return }
                    self?.activePopover?.close()
                    self?.activePopover = nil
                }
            #endif
        }

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

        #if os(macOS)
        private var activePopover: NSPopover?
        private var photoViewerCancellable: AnyCancellable?
        #endif

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? LocationAnnotation else { return }
            parent.selection = ann.location
            #if os(macOS)
            showPopover(for: ann.location, from: view)
            #endif
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            parent.selection = nil
            #if os(macOS)
            activePopover?.close()
            activePopover = nil
            #endif
        }

        #if os(macOS)
        private func showPopover(for location: ScoutLocation, from view: MKAnnotationView) {
            activePopover?.close()
            let vc = NSHostingController(rootView: LocationCalloutView(location: location))
            vc.view.frame.size = NSSize(width: 420, height: LocationCalloutView.height(for: location))
            let pop = NSPopover()
            pop.contentViewController = vc
            pop.contentSize = vc.view.frame.size
            pop.behavior = .transient
            // MKAnnotationView uses flipped coordinates (Y increases down, like iOS/screen space),
            // so .minY is the top edge → popover floats above the pin.
            pop.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            activePopover = pop
        }
        #endif

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polygon = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: polygon)
                r.fillColor   = .init(red: 0.2, green: 0.5, blue: 1, alpha: 0.12)
                r.strokeColor = .init(red: 0.2, green: 0.5, blue: 1, alpha: 0.85)
                r.lineWidth   = 2
                r.lineDashPattern = [8, 5]
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let ann = annotation as? LocationAnnotation else { return nil }
            let id = "scoutPin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKPinAnnotationView)
                ?? MKPinAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.pinTintColor = .systemRed
            view.animatesDrop = false
            #if os(macOS)
            view.canShowCallout = false  // we use NSPopover instead
            #else
            view.canShowCallout = true
            let callout = LocationCalloutView(location: ann.location)
            let size = CGSize(width: 420, height: LocationCalloutView.height(for: ann.location))
            let host = UIHostingController(rootView: callout)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = .clear
            view.detailCalloutAccessoryView = host.view
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
        // Top offset is 60 on macOS to clear the SwiftUI top bar (panel + mode toggles).
        // iOS keeps 16 because there's no equivalent bar.
        #if os(macOS)
        let topOffset: CGFloat = 60
        #else
        let topOffset: CGFloat = 16
        #endif
        NSLayoutConstraint.activate([
            subview.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16),
            subview.topAnchor.constraint(equalTo: parent.topAnchor, constant: topOffset),
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
