import SwiftUI
import MapKit
import SwiftData
import ScoutKit
import CoreVideo
import Combine

// MARK: - Imperative controller

/// Lets SwiftUI issue commands to the underlying MKMapView without binding
/// the region (which would create feedback loops on every camera change).
@MainActor
final class ScoutMapController: ObservableObject {
    @Published var userTrackingMode: MKUserTrackingMode = .none
    /// Bumped whenever `mapView` is (re)assigned so SwiftUI representables relying on
    /// it (e.g. the native tracking button) get a chance to re-wire.
    @Published private(set) var mapViewGeneration = 0

    private var trackingKVO: NSKeyValueObservation?

    weak var mapView: MKMapView? {
        didSet {
            mapViewGeneration += 1
            trackingKVO?.invalidate()
            trackingKVO = mapView?.observe(\.userTrackingMode, options: [.initial, .new]) { [weak self] map, _ in
                DispatchQueue.main.async { self?.userTrackingMode = map.userTrackingMode }
            }
        }
    }

    func toggleTracking() {
        guard let map = mapView else { return }
        if map.userTrackingMode == .follow {
            map.setUserTrackingMode(.none, animated: true)
            return
        }
        LocationManager.shared.requestIfNeeded()
        // NOTE: do NOT touch showsUserLocation here — it is set once in makeMap
        // and enforced by showsUserLocationKVO. Resetting it resets userTrackingMode.
        map.setUserTrackingMode(.follow, animated: true)
    }

    func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
        // LOCATION BUTTON INVARIANT — DO NOT REMOVE:
        // Any programmatic camera move drops MapKit's follow mode silently.
        // Always stop it explicitly first so the button icon stays in sync.
        // showsUserLocation is set ONCE in makeMap and NEVER touched here.
        // See: memory/project_scout_location_button.md
        if mapView?.userTrackingMode != .none {
            mapView?.setUserTrackingMode(.none, animated: false)
        }
        mapView?.setRegion(region, animated: animated)
    }

    func center(on coordinate: CLLocationCoordinate2D, meters: Double = 3000, animated: Bool) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters)
        setRegion(region, animated: animated)
    }

    /// Pan to coordinate preserving the current zoom level.
    func pan(to coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        guard let map = mapView else { return }
        let region = MKCoordinateRegion(center: coordinate, span: map.region.span)
        setRegion(region, animated: animated)
    }

    /// Closes any open pin popover and deselects all annotations. Call when
    /// switching away from map mode so the popover doesn't float over other views.
    func dismissPopover() {
        guard let map = mapView else { return }
        for ann in map.selectedAnnotations { map.deselectAnnotation(ann, animated: false) }
    }

    /// Deselects then immediately reselects the currently-selected annotation so
    /// MapKit fires `didSelect`, which reopens the pin popover. Call this after
    /// the carousel is dismissed while the map is in view.
    func forceReopenPopover() {
        guard let map = mapView, let ann = map.selectedAnnotations.first else { return }
        map.deselectAnnotation(ann, animated: false)
        map.selectAnnotation(ann, animated: false)
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

    // MARK: - Sequential pin reveal

    /// UUIDs of pins currently mid-reveal animation. Annotation views observe this to
    /// play their bounce-in when they first appear after a timeline GPS backfill.
    @Published var revealingPinIDs: Set<UUID> = []

    /// Fit the map to `coords`, then reveal each annotation UUID in `order` one by one,
    /// 80 ms apart. Clears the revealing set 600 ms after the last one fires.
    func revealPins(coords: [CLLocationCoordinate2D], order: [UUID], delay: TimeInterval = 0.8) {
        guard !coords.isEmpty else { return }
        fit(coords, padding: 0.3, animated: true)
        let stride: TimeInterval = 0.08
        for (i, id) in order.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(i) * stride) { [weak self] in
                self?.revealingPinIDs.insert(id)
            }
        }
        let clearAfter = delay + Double(order.count) * stride + 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) { [weak self] in
            self?.revealingPinIDs = []
        }
    }
}

// MARK: - Native user-tracking button (iOS only; macOS MapKit has no MKUserTrackingButton)

#if !os(macOS)
struct UserTrackingButtonView: UIViewRepresentable {
    @ObservedObject var controller: ScoutMapController

    func makeUIView(context: Context) -> MKUserTrackingButton {
        MKUserTrackingButton(mapView: controller.mapView)
    }
    func updateUIView(_ uiView: MKUserTrackingButton, context: Context) {
        _ = controller.mapViewGeneration
        if uiView.mapView !== controller.mapView {
            uiView.mapView = controller.mapView
        }
    }
}
#endif

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
    /// Project (saved-list) pins set this so they sync separately and carry a list color.
    let isProjectPin: Bool
    /// Hex tint for project pins; nil means the default search-result blue.
    let tintHex: String?

    var coordinate: CLLocationCoordinate2D { location.coordinate }
    var title: String? { location.name }
    var subtitle: String? { location.description.isEmpty ? nil : location.description }

    init(_ location: ScoutLocation, isProjectPin: Bool = false, tintHex: String? = nil) {
        self.location = location
        self.isProjectPin = isProjectPin
        self.tintHex = tintHex
    }

    #if os(macOS)
    var tintColor: NSColor { tintHex.flatMap { NSColor(hexString: $0) } ?? .systemBlue }
    #else
    var tintColor: UIColor { tintHex.flatMap { UIColor(hexString: $0) } ?? .systemBlue }
    #endif
}

#if os(macOS)
private extension NSColor {
    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init?(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
#endif

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
    var onBuildAnnotationMenu: ((ScoutLocation) -> NSMenu?)?
    /// Fired when the user presses "f" with the map focused (frame all project pins).
    var onFrameAllPins: (() -> Void)?
    /// Fired on double-click of a pin that has photos — opens the full-screen carousel.
    var onPinDoubleClicked: ((ScoutLocation) -> Void)?

    // MARK: - Option-click multi-selection
    /// Location IDs currently in the multi-selection (mirrors ContentView's binding).
    var multiSelectedIDs: Set<UUID> = []
    /// Called whenever the multi-selection changes so the SwiftUI binding can update.
    var onMultiSelectionChanged: ((Set<UUID>) -> Void)?

    /// Toggles a pin in/out of the multi-selection and updates its selection ring.
    private func toggleMultiSelect(_ ann: LocationAnnotation) {
        let id = ann.location.id
        if multiSelectedIDs.contains(id) { multiSelectedIDs.remove(id) }
        else { multiSelectedIDs.insert(id) }
        applySelectionRing(to: ann, selected: multiSelectedIDs.contains(id))
        onMultiSelectionChanged?(multiSelectedIDs)
    }

    /// Adds a pin to the multi-selection (no-op if already present) and rings it.
    private func addToMultiSelect(_ ann: LocationAnnotation) {
        guard !multiSelectedIDs.contains(ann.location.id) else { return }
        multiSelectedIDs.insert(ann.location.id)
        applySelectionRing(to: ann, selected: true)
        onMultiSelectionChanged?(multiSelectedIDs)
    }

    /// Clears the whole multi-selection and removes every selection ring.
    func clearMultiSelection() {
        guard !multiSelectedIDs.isEmpty else { return }
        let cleared = multiSelectedIDs
        multiSelectedIDs.removeAll()
        for ann in annotations.compactMap({ $0 as? LocationAnnotation }) where cleared.contains(ann.location.id) {
            applySelectionRing(to: ann, selected: false)
        }
        onMultiSelectionChanged?(multiSelectedIDs)
    }

    /// Applies/removes the blue selection ring on a pin's annotation view.
    func applySelectionRing(to ann: LocationAnnotation, selected: Bool) {
        guard let v = view(for: ann) else { return }
        if let photo = v as? ScoutPhotoAnnotationView {
            photo.borderColor = selected ? .systemBlue : .clear
        } else if let dot = v as? ScoutDotAnnotationView {
            dot.isMultiSelected = selected
        }
    }

    // The map accepts key events so "f" works when the map (not a text field) is focused.
    // When a TextField elsewhere is first responder, this view isn't, so typing "f" there
    // is unaffected.
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, event.charactersIgnoringModifiers == "f" {
            onFrameAllPins?()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Take key focus so "f" works without a prior click — but never steal focus from
        // a text field the user is actively editing (NSText is the field editor).
        guard let w = window, !(w.firstResponder is NSText) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, !(w.firstResponder is NSText) else { return }
            w.makeFirstResponder(self)
        }
    }

    private var drawPoints: [CGPoint] = []
    private var drawingLayer: CAShapeLayer?
    private var lastAddedPoint: CGPoint = .zero
    private let pointSpacing: CGFloat = 6

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard isDrawingMode else {
            // Select the highlighted pin directly so overlapping photos always resolve to
            // the one under the cursor (MapKit's own hit-testing can miss or pick the wrong one).
            applyHover(at: pt)
            let optionHeld = event.modifierFlags.contains(.option)
            if let ann = pinUnderCursor?.annotation as? LocationAnnotation {
                // Double-click on a pin that has photos opens the full-screen carousel.
                // (The first click of the pair opens the popover; this closes it and
                // takes over.) Single click still just opens the popover.
                if event.clickCount == 2, !optionHeld, !ann.location.images.isEmpty {
                    clearMultiSelection()
                    if let sel = selectedAnnotations.first { deselectAnnotation(sel, animated: false) }
                    onPinDoubleClicked?(ann.location)
                    return
                }
                // Option-click builds a multi-selection (no popover); plain click opens the popover.
                if optionHeld {
                    // Fold the currently-open popover pin into the multi-selection so the
                    // first plain-clicked pin isn't lost when the user starts option-clicking.
                    if let sel = selectedAnnotations.first as? LocationAnnotation {
                        deselectAnnotation(sel, animated: false)   // closes the overlay
                        addToMultiSelect(sel)
                    }
                    toggleMultiSelect(ann)
                    return
                }
                // Plain click on a pin clears any existing multi-selection first.
                clearMultiSelection()
                // Toggle: clicking the open pin closes its popover, clicking a closed pin opens it.
                let isSelected = selectedAnnotations.contains {
                    ($0 as? LocationAnnotation)?.location.id == ann.location.id
                }
                if isSelected { deselectAnnotation(ann, animated: false) }
                else { selectAnnotation(ann, animated: false) }
                return
            }
            // Option-click on empty map area: keep existing multi-selection intact and do
            // NOT call super, which runs MapKit's own hit-test and can select a nearby
            // annotation (triggering the popover) even though the user's cursor missed our
            // custom applyHover probe.
            if optionHeld { return }
            // Plain click on empty map: clear multi-selection, close any open popover, then pan.
            clearMultiSelection()
            if let sel = selectedAnnotations.first { deselectAnnotation(sel, animated: false) }
            super.mouseDown(with: event)
            return
        }
        wantsLayer = true
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

    // MARK: - Right-click context menu

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // Walk up the view hierarchy from the hit view to find an annotation view
        var candidate: NSView? = hitTest(pt)
        while let v = candidate, !(v is MKAnnotationView) { candidate = v.superview }
        if let annView = candidate as? MKAnnotationView,
           let ann = annView.annotation as? LocationAnnotation,
           let menu = onBuildAnnotationMenu?(ann.location) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.rightMouseDown(with: event)
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

    // MARK: - Dot hover

    private var magTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = magTrackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        magTrackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isDrawingMode else { return }
        applyHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(nil)
    }

    private weak var hoveredView: MKAnnotationView?

    /// Highlights the single pin under the cursor (the nearest one when photos overlap).
    /// Hit-tested against each pin's full on-screen frame, so the whole photo — border
    /// included — is hoverable.
    private func applyHover(at point: CGPoint) {
        // Query MapKit's spatial index for just the annotations near the cursor instead of
        // scanning every visible annotation. With thousands of pins this turns an O(visible)
        // scan on every mouse-move into O(handful). The probe radius covers the largest pin
        // (a 50pt photo, scaled) plus margin so a pin whose center sits just outside the
        // cursor still registers.
        let probeRadius: CGFloat = 60
        let rect = CGRect(x: point.x - probeRadius, y: point.y - probeRadius,
                          width: probeRadius * 2, height: probeRadius * 2)
        let c1 = MKMapPoint(convert(CGPoint(x: rect.minX, y: rect.minY), toCoordinateFrom: self))
        let c2 = MKMapPoint(convert(CGPoint(x: rect.maxX, y: rect.maxY), toCoordinateFrom: self))
        let probe = MKMapRect(x: min(c1.x, c2.x), y: min(c1.y, c2.y),
                              width: abs(c1.x - c2.x), height: abs(c1.y - c2.y))

        var best: MKAnnotationView?
        var bestDist = CGFloat.infinity
        for ann in annotations(in: probe) {
            guard let mkAnn = ann as? (any MKAnnotation),
                  let av = view(for: mkAnn),
                  av is ScoutDotAnnotationView || av is ScoutPhotoAnnotationView else { continue }
            var hit = convert(av.frame, from: av.superview)
            // Small pins (dots) get a generous minimum target; photos use their true size.
            let minSize: CGFloat = 24
            if hit.width < minSize {
                hit = hit.insetBy(dx: -(minSize - hit.width) / 2, dy: -(minSize - hit.height) / 2)
            }
            guard hit.contains(point) else { continue }
            let d = hypot(hit.midX - point.x, hit.midY - point.y)
            if d < bestDist { bestDist = d; best = av }
        }
        setHovered(best)
    }

    private func setHovered(_ av: MKAnnotationView?) {
        guard av !== hoveredView else { return }
        apply(hover: false, to: hoveredView)
        apply(hover: true, to: av)
        hoveredView = av
    }

    private func apply(hover: Bool, to av: MKAnnotationView?) {
        (av as? ScoutDotAnnotationView)?.isHovered = hover
        if let photo = av as? ScoutPhotoAnnotationView {
            photo.isHovered = hover
            // Raise the NSView in its parent (view-tree order) AND set CALayer zPosition
            // so the hovered photo is unambiguously above all siblings.
            if hover {
                photo.layer?.zPosition = 100
                photo.superview?.addSubview(photo)   // moves to last (topmost) sibling
            } else {
                photo.layer?.zPosition = 0
            }
        }
    }

    /// The pin currently under the cursor, if any — used to make clicks always hit the
    /// highlighted pin even when photos overlap.
    var pinUnderCursor: MKAnnotationView? { hoveredView }

}

// MARK: - Dot annotation view

final class ScoutDotAnnotationView: MKAnnotationView {
    static let reuseID = "scoutDot"

    var dotColor: NSColor = .systemBlue {
        didSet { needsDisplay = true }
    }

    /// Driven by ZoomableMapView's mouseMoved — triggers a ring-pulse redraw.
    var isHovered: Bool = false {
        didSet { guard oldValue != isHovered else { return }; needsDisplay = true }
    }
    /// True when part of the map multi-selection — draws a blue outer ring.
    var isMultiSelected: Bool = false {
        didSet { guard oldValue != isMultiSelected else { return }; needsDisplay = true }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        wantsLayer = true
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func reveal() {
        guard let layer else { return }
        layer.transform = CATransform3DMakeScale(0, 0, 1)
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values   = [0, 1.5, 0.85, 1.1, 1.0]
        anim.keyTimes = [0, 0.35, 0.6, 0.8, 1.0]
        anim.duration = 0.45
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "revealBounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) {
            layer.transform = CATransform3DIdentity
            layer.removeAnimation(forKey: "revealBounce")
        }
    }

    static let baseSize: CGFloat = 14
    func setScale(_ scale: CGFloat) {
        let s = Self.baseSize * max(scale, 0.2)
        guard abs(bounds.width - s) > 0.5 else { return }
        // Resize about the current center so the pin grows in place. Setting bounds alone
        // keeps frame.origin fixed (the pin appears to drift until MapKit's next layout).
        let c = CGPoint(x: frame.midX, y: frame.midY)
        frame = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Scale ring geometry with the view so proportions hold at any pin size.
        let ratio = max(bounds.width / Self.baseSize, 0.01)
        let inset: CGFloat = (isHovered ? 0.5 : 1.5) * ratio
        let ringWidth: CGFloat = (isHovered ? 3.5 : 2.5) * ratio
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let oval = NSBezierPath(ovalIn: rect)

        // Solid fill.
        dotColor.setFill()
        oval.fill()

        // White ring on top frames the dot.
        NSColor.white.withAlphaComponent(isHovered ? 1.0 : 0.9).setStroke()
        oval.lineWidth = ringWidth
        oval.stroke()

        // Blue selection ring drawn just outside the white ring.
        if isMultiSelected {
            let selPath = NSBezierPath(ovalIn: bounds.insetBy(dx: inset * 0.2, dy: inset * 0.2))
            NSColor.systemBlue.setStroke()
            selPath.lineWidth = ringWidth * 1.1
            selPath.stroke()
        }
    }
}

// MARK: - Photo annotation view

final class ScoutPhotoAnnotationView: MKAnnotationView {
    static let reuseID = "scoutPhoto"

    /// CALayer used instead of NSImageView so we get contentsGravity = .resizeAspectFill
    /// (fill+crop) which NSImageView cannot do natively.
    private let photoLayer = CALayer()
    private var loadTask: Task<Void, Never>?
    private var currentScale: CGFloat = 1.0

    var isHovered: Bool = false {
        didSet { guard oldValue != isHovered else { return }; applyBorder() }
    }
    var borderColor: NSColor = .white {
        didSet { guard oldValue != borderColor else { return }; applyBorder() }
    }
    private func applyBorder() {
        let ratio = bounds.width / Self.baseSize
        layer?.borderWidth = (isHovered ? 5 : 2.5) * ratio
        layer?.borderColor = borderColor.cgColor
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size: CGFloat = Self.baseSize
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        wantsLayer = true
        canShowCallout = false

        layer?.cornerRadius = 8
        layer?.borderWidth = 2.5
        layer?.borderColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false

        photoLayer.frame = bounds
        photoLayer.contentsGravity = .resizeAspectFill   // fill + center-crop
        photoLayer.masksToBounds = true
        photoLayer.cornerRadius = 6
        photoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(photoLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    func reveal() {
        guard let layer else { return }
        layer.transform = CATransform3DMakeScale(0, 0, 1)
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values   = [0, 1.4, 0.9, 1.05, 1.0]
        anim.keyTimes = [0, 0.3, 0.6, 0.8, 1.0]
        anim.duration = 0.5
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        layer.add(anim, forKey: "revealBounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.51) {
            layer.transform = CATransform3DIdentity
            layer.removeAnimation(forKey: "revealBounce")
        }
    }

    static let baseSize: CGFloat = 50

    func setScale(_ scale: CGFloat) {
        currentScale = max(scale, 0.2)
        applySize()
    }

    private func applySize() {
        let s = Self.baseSize * currentScale
        guard abs(bounds.width - s) > 0.5 else { return }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        frame = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
        photoLayer.frame = bounds
        let ratio = s / Self.baseSize
        layer?.cornerRadius = 8 * ratio
        layer?.shadowRadius = 4 * ratio
        photoLayer.cornerRadius = 6 * ratio
        applyBorder()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.setAffineTransform(.identity)
        layer?.zPosition = 0
        isHovered = false
        currentScale = 1.0
        photoLayer.contents = nil
    }

    func configure(imageURL: URL?, rotationQuarterTurns: Int = 0) {
        loadTask?.cancel()
        if let url = imageURL, let cached = PhotoLoader.cached(url) {
            let rotated = cached.rotatedCCW(quarterTurns: rotationQuarterTurns)
            photoLayer.contents = rotated.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return
        }
        photoLayer.contents = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let url = imageURL else { return }
        loadTask = Task {
            let img = await PhotoLoader.load(url)
            guard !Task.isCancelled, let img else { return }
            await MainActor.run {
                let rotated = img.rotatedCCW(quarterTurns: rotationQuarterTurns)
                self.photoLayer.contents = rotated.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
    }
}

#endif

// MARK: - Boundary name language

enum BoundaryNameLanguage: String, CaseIterable, RawRepresentable {
    case japanese, english, both
    var label: String {
        switch self { case .japanese: "Japanese"; case .english: "English"; case .both: "Both" }
    }
}

// MARK: - Boundary polygon (MKPolygon subclass carries color + name)

final class BoundaryPolygon: MKPolygon {
    var boundaryName: String = ""
    var boundaryNameEn: String? = nil
    var colorIndex: Int = 0

    static let palette: [CGColor] = [
        CGColor(red: 0.28, green: 0.53, blue: 0.90, alpha: 1),
        CGColor(red: 0.22, green: 0.71, blue: 0.55, alpha: 1),
        CGColor(red: 0.94, green: 0.57, blue: 0.18, alpha: 1),
        CGColor(red: 0.76, green: 0.32, blue: 0.64, alpha: 1),
        CGColor(red: 0.87, green: 0.77, blue: 0.11, alpha: 1),
        CGColor(red: 0.84, green: 0.28, blue: 0.28, alpha: 1),
        CGColor(red: 0.26, green: 0.63, blue: 0.30, alpha: 1),
        CGColor(red: 0.55, green: 0.40, blue: 0.78, alpha: 1),
        CGColor(red: 0.15, green: 0.62, blue: 0.74, alpha: 1),
        CGColor(red: 0.91, green: 0.38, blue: 0.54, alpha: 1),
        CGColor(red: 0.57, green: 0.74, blue: 0.30, alpha: 1),
        CGColor(red: 0.78, green: 0.51, blue: 0.20, alpha: 1),
    ]

    var baseColor: CGColor { BoundaryPolygon.palette[colorIndex % BoundaryPolygon.palette.count] }
}

// MARK: - Boundary label annotation

final class BoundaryLabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let colorIndex: Int
    init(_ name: String, at coordinate: CLLocationCoordinate2D, colorIndex: Int) {
        self.coordinate = coordinate
        self.title = name
        self.colorIndex = colorIndex
    }
}

#if os(macOS)
// MARK: - Boundary label annotation view

final class BoundaryLabelView: MKAnnotationView {
    static let reuseID = "boundaryLabel"

    var labelText: String = "" { didSet { needsDisplay = true; updateLabelSize() } }
    var colorIndex: Int = 0 { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 17 { didSet { needsDisplay = true; updateLabelSize() } }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint) -> NSView? { nil }

    private func updateLabelSize() {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let size = (labelText as NSString).size(withAttributes: [.font: font])
        frame.size = CGSize(width: ceil(size.width) + 10, height: ceil(size.height) + 6)
    }

    override func draw(_ rect: NSRect) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let color = BoundaryPolygon.palette[colorIndex % BoundaryPolygon.palette.count]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .shadow: shadow,
            .strokeColor: NSColor.black.withAlphaComponent(0.5),
            .strokeWidth: -1.5,
        ]
        (labelText as NSString).draw(in: bounds.insetBy(dx: 5, dy: 3), withAttributes: attrs)
    }
}
#endif

// MARK: - Menu action helper (macOS)

#if os(macOS)
final class MenuAction: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}
#endif

// MARK: - Representable

struct ScoutMapView {
    @Binding var selection: ScoutLocation?
    /// Option-click multi-selection of pin location IDs (for batch move-to-list).
    @Binding var mapSelection: Set<UUID>
    var locations: [ScoutLocation]
    var projectPins: [(ScoutLocation, String)] = []  // (location, colorHex)
    var scrollToZoom: Bool
    var initialRegion: MKCoordinateRegion?
    var controller: ScoutMapController
    var onRegionEnd: (MKCoordinateRegion) -> Void
    var isDrawingMode: Bool = false
    var searchPolygon: [CLLocationCoordinate2D]? = nil
    var onPolygonComplete: ([CLLocationCoordinate2D]) -> Void = { _ in }
    var onFrameAllPins: () -> Void = {}
    /// Called when the map is clicked on empty space (deselect).
    var onMapDeselect: (() -> Void)? = nil
    /// Called on double-click of a pin that has photos — opens the full-screen carousel.
    var onPinDoubleClicked: ((ScoutLocation) -> Void)? = nil
    var mapType: MKMapType = .standard
    var cyclingProvider: CyclingTileProvider? = nil
    var showPhotoAnnotations: Bool = false
    var pinScale: Double = 1.0
    var availableLists: [LocationListData] = []
    var onSaveToList: ((ScoutLocation, LocationListData) -> Void)? = nil
    /// Right-click "Move N photos to list…" on a multi-selection — opens the move picker.
    var onMoveSelectionToList: (() -> Void)? = nil
    /// True when the currently-selected location is an already-saved pin — enables drag-to-list.
    var isSelectedPinned: Bool = false
    var boundaryPolygons: [BoundaryPolygon] = []
    var boundaryOpacity: Double = 0.2
    var showBoundaryNames: Bool = true
    var boundaryNameLanguage: BoundaryNameLanguage = .japanese

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeMap(context: Context) -> MKMapView {
        #if os(macOS)
        let map = ZoomableMapView()
        map.showsZoomControls = true
        map.showsPitchControl = false
        map.isPitchEnabled = false
        #else
        let map = MKMapView()
        #endif
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 1)
        #if os(macOS)
        map.showsScale = true
        #endif

        if let initialRegion {
            map.setRegion(initialRegion, animated: false)
        }

        Task { @MainActor in
            controller.mapView = map
            context.coordinator.wireReveal(controller: controller, mapView: map)
        }
        return map
    }

    private func updateMap(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        #if os(macOS)
        if let zoomable = map as? ZoomableMapView {
            zoomable.scrollZoomEnabled = scrollToZoom
            zoomable.isDrawingMode = isDrawingMode
            zoomable.onPolygonComplete = onPolygonComplete
            zoomable.onFrameAllPins = onFrameAllPins
            zoomable.onPinDoubleClicked = onPinDoubleClicked
            zoomable.onBuildAnnotationMenu = { [weak coordinator = context.coordinator] location in
                coordinator?.buildAnnotationMenu(for: location)
            }
            zoomable.onMultiSelectionChanged = { ids in
                // Update synchronously. An async hop leaves a window where the view's
                // multiSelectedIDs is ahead of this binding; an unrelated re-render in
                // that window (e.g. popover deselect → onMapDeselect → rebuildPinCaches)
                // runs the reconciliation below and wipes the just-added pin's ring —
                // which is why option-click could never build up more than one selection.
                // Mouse events never fire during a SwiftUI view update, so a synchronous
                // binding write here is safe.
                mapSelection = ids
            }
            // Reconcile the view's selection rings when the binding changes externally
            // (e.g. cleared after a batch move, or restored). Handle both directions.
            if zoomable.multiSelectedIDs != mapSelection {
                let removed = zoomable.multiSelectedIDs.subtracting(mapSelection)
                let added = mapSelection.subtracting(zoomable.multiSelectedIDs)
                zoomable.multiSelectedIDs = mapSelection
                for ann in zoomable.annotations.compactMap({ $0 as? LocationAnnotation }) {
                    if removed.contains(ann.location.id) {
                        zoomable.applySelectionRing(to: ann, selected: false)
                    } else if added.contains(ann.location.id) {
                        zoomable.applySelectionRing(to: ann, selected: true)
                    }
                }
            }
        }
        #endif
        // NOTE: showsUserLocation is set once in makeMap and deliberately never
        // re-asserted here. Toggling it false→true resets userTrackingMode and is
        // what repeatedly broke the "follow me" button. Leave it alone.
        if map.mapType != mapType {
            map.mapType = mapType
        }
        let coord = context.coordinator
        // Photo mode changes the view *class*, so force viewFor: to re-run by recycling.
        if coord.lastPhotoAnnotationsMode != showPhotoAnnotations {
            coord.lastPhotoAnnotationsMode = showPhotoAnnotations
            let toRecycle = map.annotations.filter { !($0 is MKUserLocation) && !($0 is BoundaryLabelAnnotation) }
            map.removeAnnotations(toRecycle)
            map.addAnnotations(toRecycle)
        } else if abs(coord.lastPinScale - pinScale) > 0.001 {
            // Pin size only changes geometry, not the view class — resize in place.
            // This avoids the flicker (and photo reload) of removing/re-adding pins
            // on every slider tick. Off-screen pins are recreated at the right size
            // by viewFor: (which reads parent.pinScale) when they scroll into view.
            #if os(macOS)
            let scale = CGFloat(pinScale)
            // Only resize visible annotation views — off-screen ones pick up the new
            // scale from parent.pinScale when they're next dequeued by viewFor:.
            for ann in map.annotations(in: map.visibleMapRect).compactMap({ $0 as? LocationAnnotation }) {
                switch map.view(for: ann) {
                case let dot as ScoutDotAnnotationView:     dot.setScale(scale)
                case let photo as ScoutPhotoAnnotationView: photo.setScale(scale)
                default: break
                }
            }
            // Also resize the user location dot so it matches other pins.
            if let userLocView = map.view(for: map.userLocation) as? ScoutDotAnnotationView {
                userLocView.setScale(scale)
            }
            #endif
        }
        coord.lastPinScale = pinScale
        context.coordinator.syncAnnotations(map, desired: locations.map { ($0, nil) }, projectPins: false)
        context.coordinator.syncAnnotations(map, desired: projectPins.map { ($0.0, $0.1) }, projectPins: true)
        context.coordinator.syncSelection(map, selection: selection)
        syncTileOverlay(map)
        syncPolygonOverlay(map)
        context.coordinator.syncBoundaryOverlays(map, polygons: boundaryPolygons,
                                                 opacity: boundaryOpacity,
                                                 showNames: showBoundaryNames,
                                                 nameLanguage: boundaryNameLanguage)
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
        // Only remove plain MKPolygons (search area), not BoundaryPolygon subclasses
        let existing = map.overlays.compactMap { $0 as? MKPolygon }.filter { !($0 is BoundaryPolygon) }
        map.removeOverlays(existing)
        if var coords = searchPolygon, coords.count >= 3 {
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

        // Stable index of live annotations — keyed by UUID for O(1) lookup.
        private var searchIndex:  [UUID: LocationAnnotation] = [:]
        private var projectIndex: [UUID: LocationAnnotation] = [:]
        private var lastSearchSig:  Int = 0
        private var lastProjectSig: Int = 0

        /// True incremental diff: adds only new annotations, removes only stale ones, and
        /// updates tint/image in-place — so a 1000-pin project that hasn't changed costs
        /// just an O(n) hash check followed by nothing, instead of 2000 MapKit calls.
        func syncAnnotations(_ map: MKMapView, desired: [(ScoutLocation, String?)], projectPins: Bool) {
            // Fast signature check — bail immediately if nothing changed.
            var hasher = Hasher()
            for (loc, tint) in desired {
                hasher.combine(loc.id)
                hasher.combine(tint)
                hasher.combine(loc.images.first?.url)
            }
            let sig = hasher.finalize()
            if projectPins {
                guard sig != lastProjectSig else { return }
                lastProjectSig = sig
            } else {
                guard sig != lastSearchSig else { return }
                lastSearchSig = sig
            }

            var index = projectPins ? projectIndex : searchIndex

            // Build desired lookup: id → (location, tint, imageURL). Use uniquingKeysWith
            // (keep first) so a stray duplicate id can never crash the map rebuild — a pin
            // briefly appearing twice during a move should drop a dupe, not trap.
            var desiredMap: [UUID: (ScoutLocation, String?)] = Dictionary(
                desired.map { ($0.0.id, ($0.0, $0.1)) },
                uniquingKeysWith: { first, _ in first }
            )

            // Remove annotations that are no longer desired.
            var toRemove: [LocationAnnotation] = []
            for (id, ann) in index where desiredMap[id] == nil {
                toRemove.append(ann)
                index.removeValue(forKey: id)
            }
            if !toRemove.isEmpty { map.removeAnnotations(toRemove) }

            // Update in-place where tint or image changed; add truly new ones.
            var toAdd: [LocationAnnotation] = []
            for (id, (loc, tint)) in desiredMap {
                if let existing = index[id] {
                    // Already on map — update tint color without remove/add if it changed.
                    if existing.tintHex != tint {
                        let replacement = LocationAnnotation(loc, isProjectPin: projectPins, tintHex: tint)
                        map.removeAnnotation(existing)
                        toAdd.append(replacement)
                        index[id] = replacement
                    }
                    // Image URL change: let the view update on next viewFor: (annotation unchanged).
                } else {
                    let ann = LocationAnnotation(loc, isProjectPin: projectPins, tintHex: tint)
                    toAdd.append(ann)
                    index[id] = ann
                }
            }
            if !toAdd.isEmpty { map.addAnnotations(toAdd) }

            if projectPins { projectIndex = index } else { searchIndex = index }
        }

        func syncSelection(_ map: MKMapView, selection: ScoutLocation?) {
            let selected = map.selectedAnnotations.compactMap { $0 as? LocationAnnotation }.first

            if let selection,
               let annotation = searchIndex[selection.id] ?? projectIndex[selection.id] {
                if selected?.location.id != selection.id {
                    map.selectAnnotation(annotation, animated: false)
                } else {
                    #if os(macOS)
                    if let view = map.view(for: annotation), activePopover == nil {
                        // Annotation is already selected but popover was closed — reopen it.
                        showPopover(for: selection, from: view, in: map)
                    }
                    #endif
                }
            } else if selection == nil,
                      let current = map.selectedAnnotations.first(where: { $0 is LocationAnnotation }) {
                map.deselectAnnotation(current, animated: false)
            }
        }

        // MARK: - Boundary overlay sync

        private var currentBoundaryOpacity: Double = -1
        private var currentBoundaryCount: Int = -1
        private var currentShowBoundaryNames: Bool = false
        private var currentNameLanguage: BoundaryNameLanguage = .japanese

        func syncBoundaryOverlays(_ map: MKMapView, polygons: [BoundaryPolygon], opacity: Double,
                                   showNames: Bool, nameLanguage: BoundaryNameLanguage) {
            let opacityChanged = abs(opacity - currentBoundaryOpacity) > 0.001
            let countChanged = polygons.count != currentBoundaryCount
            let namesChanged = showNames != currentShowBoundaryNames
            let langChanged = nameLanguage != currentNameLanguage

            if countChanged || opacityChanged {
                let old = map.overlays.compactMap { $0 as? BoundaryPolygon }
                map.removeOverlays(old)
                if !polygons.isEmpty {
                    map.addOverlays(polygons as [MKOverlay], level: .aboveRoads)
                }
                currentBoundaryOpacity = opacity
                currentBoundaryCount = polygons.count
            }

            if countChanged || namesChanged || langChanged {
                let old = map.annotations.compactMap { $0 as? BoundaryLabelAnnotation }
                map.removeAnnotations(old)
                if showNames && !polygons.isEmpty {
                    var seen = Set<String>()
                    var labels: [BoundaryLabelAnnotation] = []
                    for poly in polygons {
                        guard !seen.contains(poly.boundaryName) else { continue }
                        seen.insert(poly.boundaryName)
                        var coords = [CLLocationCoordinate2D](repeating: .init(), count: poly.pointCount)
                        poly.getCoordinates(&coords, range: NSRange(location: 0, length: poly.pointCount))
                        let lat = coords.isEmpty ? 0 : coords.map(\.latitude).reduce(0, +) / Double(coords.count)
                        let lon = coords.isEmpty ? 0 : coords.map(\.longitude).reduce(0, +) / Double(coords.count)
                        let displayName = labelText(ja: poly.boundaryName, en: poly.boundaryNameEn,
                                                     language: nameLanguage)
                        labels.append(BoundaryLabelAnnotation(displayName,
                                                              at: .init(latitude: lat, longitude: lon),
                                                              colorIndex: poly.colorIndex))
                    }
                    map.addAnnotations(labels)
                }
                currentShowBoundaryNames = showNames
                currentNameLanguage = nameLanguage
            }
        }

        private func labelText(ja: String, en: String?, language: BoundaryNameLanguage) -> String {
            switch language {
            case .japanese: return ja
            case .english:  return en ?? ja
            case .both:     return en.map { "\($0)\n\(ja)" } ?? ja
            }
        }

        private var regionSaveWork: DispatchWorkItem?
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // Debounce: during scroll-zoom / pan this fires every display frame. Writing
            // the region straight through hits @AppStorage every frame, which re-renders
            // ContentView → updateMap → syncAnnotations (O(pins)) on every frame and tanks
            // the framerate. Coalesce to a single write after the gesture settles.
            regionSaveWork?.cancel()
            let region = mapView.region
            let work = DispatchWorkItem { [weak self] in self?.parent.onRegionEnd(region) }
            regionSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)

            // When crossing the photo↔dot zoom threshold, recycle visible annotation views
            // so viewFor: can immediately swap between photo and dot renderers.
            let spanKm = region.span.latitudeDelta * 111
            let bucket = spanKm < 80 ? 0 : 1
            if bucket != lastSpanKmBucket {
                lastSpanKmBucket = bucket
                // Update the stable flag BEFORE recycling so every viewFor: call in this
                // batch sees the same decision — prevents mixed photo/dot states.
                currentShowPhotoSpan = (bucket == 0)
                let visible: [LocationAnnotation] = mapView.annotations(in: mapView.visibleMapRect)
                    .compactMap { $0 as? LocationAnnotation }
                if !visible.isEmpty {
                    mapView.removeAnnotations(visible)
                    mapView.addAnnotations(visible)
                }
            }
        }

        #if os(macOS)
        private var activePopover: NSPopover?
        private var photoViewerCancellable: AnyCancellable?
        private var revealCancellable: AnyCancellable?
        #endif

        func wireReveal(controller: ScoutMapController, mapView: MKMapView) {
            #if os(macOS)
            revealCancellable = controller.$revealingPinIDs
                .receive(on: DispatchQueue.main)
                .sink { [weak mapView] ids in
                    guard !ids.isEmpty else { return }
                    // For each newly-revealing pin, call reveal() on its existing annotation
                    // view if visible, or recycle it so viewFor: fires with the id in the set.
                    for ann in mapView?.annotations ?? [] {
                        guard let locAnn = ann as? LocationAnnotation,
                              ids.contains(locAnn.location.id) else { continue }
                        if let dot = mapView?.view(for: ann) as? ScoutDotAnnotationView {
                            dot.reveal()
                        } else if let photo = mapView?.view(for: ann) as? ScoutPhotoAnnotationView {
                            photo.reveal()
                        }
                    }
                }
            #endif
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let ann = view.annotation as? LocationAnnotation else { return }
            // Blue selection ring — store original border color so we can restore it on deselect.
            #if os(macOS)
            if let photo = view as? ScoutPhotoAnnotationView {
                photo.borderColor = .systemBlue
            } else if let dot = view as? ScoutDotAnnotationView {
                dot.dotColor = .systemBlue
            }
            #endif
            DispatchQueue.main.async {
                self.parent.selection = ann.location
            }
            #if os(macOS)
            showPopover(for: ann.location, from: view, in: mapView)
            #endif
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            // Restore the original border/dot color from the annotation's tintHex.
            #if os(macOS)
            if let ann = view.annotation as? LocationAnnotation {
                if let photo = view as? ScoutPhotoAnnotationView {
                    photo.borderColor = .clear   // no colored frame on map photos
                } else if let dot = view as? ScoutDotAnnotationView {
                    dot.dotColor = ann.tintColor
                }
            }
            #endif
            DispatchQueue.main.async {
                self.parent.selection = nil
                self.parent.onMapDeselect?()
            }
            #if os(macOS)
            activePopover?.close()
            activePopover = nil
            #endif
        }

        #if os(macOS)
        private func showPopover(for location: ScoutLocation, from annotationView: MKAnnotationView, in mapView: MKMapView) {
            // Never show the map callout while the full-screen carousel is up — otherwise the
            // popover can appear floating on top of it. This is the hard guarantee; the
            // .onChange(photoViewer.isVisible) dismiss handles the already-open case.
            if PhotoViewerState.shared.isVisible { return }
            activePopover?.close()
            let lists = parent.availableLists
            let saveHandler = parent.onSaveToList
            let callout = LocationCalloutView(
                location: location,
                availableLists: lists,
                onSaveToList: saveHandler.map { handler in { list in handler(location, list) } },
                isPinned: parent.isSelectedPinned
            )
            let vc = NSHostingController(rootView: callout)
            let height = LocationCalloutView.height(for: location, hasLists: !lists.isEmpty)
            vc.view.frame.size = NSSize(width: 420, height: height)
            let pop = NSPopover()
            pop.contentViewController = vc
            pop.contentSize = vc.view.frame.size
            // Application-defined (not .transient): a transient popover eats the dismiss
            // click while leaving the pin selected, which broke re-opening. We toggle
            // open/close explicitly in mouseDown instead.
            pop.behavior = .applicationDefined
            pop.animates = false   // appear instantly on click instead of fading in

            // MKAnnotationView uses flipped coordinates (Y increases downward), so minY=0
            // is the top edge. .minY preferred edge makes the popover appear above the photo.
            let anchorY = annotationView.bounds.minY + 1
            let anchor = NSRect(x: annotationView.bounds.midX - 0.5,
                                y: anchorY, width: 1, height: 1)
            pop.show(relativeTo: anchor, of: annotationView, preferredEdge: .minY)
            activePopover = pop
        }

        // Builds an NSMenu for right-click on an annotation, with "Save to List" submenu.
        func buildAnnotationMenu(for location: ScoutLocation) -> NSMenu? {
            guard !parent.availableLists.isEmpty, let handler = parent.onSaveToList else { return nil }
            let menu = NSMenu()

            // Multi-selection: one item that opens the move picker for all selected pins.
            let selectionCount = parent.mapSelection.count
            if selectionCount >= 2, let moveSelection = parent.onMoveSelectionToList {
                let act = MenuAction { moveSelection() }
                menuActions.append(act)
                let item = NSMenuItem(title: "Move \(selectionCount) photos to list…",
                                      action: #selector(MenuAction.invoke), keyEquivalent: "")
                item.target = act
                menu.addItem(item)
                return menu
            }

            let saveItem = NSMenuItem(title: "Save to List", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for list in parent.availableLists {
                let act = MenuAction { handler(location, list) }
                menuActions.append(act)
                let item = NSMenuItem(title: list.name, action: #selector(MenuAction.invoke), keyEquivalent: "")
                item.target = act
                submenu.addItem(item)
            }
            saveItem.submenu = submenu
            menu.addItem(saveItem)
            return menu
        }

        private var menuActions: [MenuAction] = []
        #endif

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let boundary = overlay as? BoundaryPolygon {
                let r = MKPolygonRenderer(polygon: boundary)
                let opacity = parent.boundaryOpacity
                let base = boundary.baseColor
                #if os(macOS)
                r.fillColor   = NSColor(cgColor: base)?.withAlphaComponent(CGFloat(opacity))
                r.strokeColor = NSColor(cgColor: base)?.withAlphaComponent(min(CGFloat(opacity) * 3, 0.85))
                #else
                r.fillColor   = UIColor(cgColor: base).withAlphaComponent(CGFloat(opacity))
                r.strokeColor = UIColor(cgColor: base).withAlphaComponent(min(CGFloat(opacity) * 3, 0.85))
                #endif
                r.lineWidth   = 1
                return r
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

        var lastPhotoAnnotationsMode: Bool = false
        var lastPinScale: Double = 1.0
        var lastSpanKmBucket: Int = 0   // tracks coarse zoom bucket to trigger photo↔dot swap
        /// Stable show-photo decision used by viewFor: — set in regionDidChangeAnimated BEFORE
        /// the recycle pass so every view created in that batch sees the same value.
        var currentShowPhotoSpan: Bool = true

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // User location: render as a standard blue dot at the same scale as other pins.
            if annotation is MKUserLocation {
                #if os(macOS)
                let id = "userLocationDot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? ScoutDotAnnotationView)
                    ?? ScoutDotAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.dotColor = .systemBlue
                view.setScale(CGFloat(parent.pinScale))
                view.displayPriority = .required
                // Always float above every other pin/photo (hover uses 100, so go far higher).
                view.layer?.zPosition = 10_000
                return view
                #else
                // iOS: use the system default blue user-location dot.
                return nil
                #endif
            }
            if let ann = annotation as? LocationAnnotation {
                #if os(macOS)
                let scale = CGFloat(parent.pinScale)
                // Photo annotations only make sense when the pin actually has an image.
                // Suppress photo loading when zoomed far out — loading hundreds of
                // thumbnail images simultaneously tanks frame rate. Switch to dots below
                // ~10 km span; photos look like blobs at that scale anyway.
                // Use the stable flag set in regionDidChangeAnimated — NOT live span —
                // so every view created in one batch sees the same photo/dot decision.
                let showPhoto = parent.showPhotoAnnotations
                    && ann.location.images.first?.url != nil
                    && currentShowPhotoSpan
                if showPhoto {
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: ScoutPhotoAnnotationView.reuseID) as? ScoutPhotoAnnotationView)
                        ?? ScoutPhotoAnnotationView(annotation: annotation, reuseIdentifier: ScoutPhotoAnnotationView.reuseID)
                    view.annotation = annotation
                    // No colored frame normally; blue ring when in the multi-selection.
                    let selected = (mapView as? ZoomableMapView)?.multiSelectedIDs.contains(ann.location.id) ?? false
                    view.borderColor = selected ? .systemBlue : .clear
                    view.setScale(scale)
                    view.configure(imageURL: ann.location.images.first?.url,
                                   rotationQuarterTurns: ann.location.images.first?.rotationQuarterTurns ?? 0)
                    if parent.controller.revealingPinIDs.contains(ann.location.id) {
                        view.reveal()
                    }
                    return view
                } else {
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: ScoutDotAnnotationView.reuseID) as? ScoutDotAnnotationView)
                        ?? ScoutDotAnnotationView(annotation: annotation, reuseIdentifier: ScoutDotAnnotationView.reuseID)
                    view.annotation = annotation
                    view.dotColor = ann.tintColor
                    view.isMultiSelected = (mapView as? ZoomableMapView)?.multiSelectedIDs.contains(ann.location.id) ?? false
                    view.setScale(scale)
                    if parent.controller.revealingPinIDs.contains(ann.location.id) {
                        view.reveal()
                    }
                    return view
                }
                #else
                let id = "scoutPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = ann.tintColor
                view.canShowCallout = true
                let callout = LocationCalloutView(location: ann.location)
                let size = CGSize(width: 420, height: LocationCalloutView.height(for: ann.location))
                let host = UIHostingController(rootView: callout)
                host.view.frame = CGRect(origin: .zero, size: size)
                host.view.backgroundColor = .clear
                view.detailCalloutAccessoryView = host.view
                return view
                #endif
            }

            #if os(macOS)
            if let label = annotation as? BoundaryLabelAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: BoundaryLabelView.reuseID) as? BoundaryLabelView)
                    ?? BoundaryLabelView(annotation: annotation, reuseIdentifier: BoundaryLabelView.reuseID)
                view.annotation = annotation
                view.labelText = label.title ?? ""
                view.colorIndex = label.colorIndex
                view.displayPriority = .defaultLow
                return view
            }
            #endif

            return nil
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

