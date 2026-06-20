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

    private var trackingKVO: NSKeyValueObservation?

    weak var mapView: MKMapView? {
        didSet {
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
        // Engaging follow: make sure every precondition MapKit needs is in place,
        // otherwise it silently reverts the mode back to .none.
        LocationManager.shared.requestIfNeeded()
        if !map.showsUserLocation { map.showsUserLocation = true }
        map.setUserTrackingMode(.follow, animated: true)
    }

    func setRegion(_ region: MKCoordinateRegion, animated: Bool) {
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

final class ProjectAnnotation: NSObject, MKAnnotation {
    let location: ScoutLocation
    let colorHex: String
    var coordinate: CLLocationCoordinate2D { location.coordinate }
    var title: String? { location.name }
    var subtitle: String? { location.description.isEmpty ? nil : location.description }
    init(_ location: ScoutLocation, colorHex: String) {
        self.location = location
        self.colorHex = colorHex
    }

    #if os(macOS)
    var pinColor: NSColor { NSColor(hexString: colorHex) ?? .systemOrange }
    #else
    var pinColor: UIColor { UIColor(hexString: colorHex) ?? .systemOrange }
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

    // MARK: - Dock magnification

    /// Only active in photo mode — set by updateMap when showPhotoAnnotations changes.
    var photoMagnificationEnabled = false
    /// The currently-selected annotation view; pinned at maxScale while popover is open.
    weak var selectedAnnotationView: ScoutPhotoAnnotationView?

    private var magTrackingArea: NSTrackingArea?
    private let magMaxScale: CGFloat = 4.5
    private let magInfluenceRadius: CGFloat = 180

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
        let pt = convert(event.locationInWindow, from: nil)
        if photoMagnificationEnabled {
            applyDockMagnification(at: pt)
        } else {
            applyDotHover(at: pt)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if photoMagnificationEnabled { resetMagnification() } else { clearDotHover() }
    }

    private var hoveredDotView: ScoutDotAnnotationView?

    private func applyDotHover(at point: CGPoint) {
        let hoverRadius: CGFloat = 12
        var nearest: ScoutDotAnnotationView? = nil
        var nearestDist: CGFloat = .infinity
        for ann in annotations(in: visibleMapRect).prefix(300) {
            guard let mkAnn = ann as? (any MKAnnotation),
                  let av = view(for: mkAnn) as? ScoutDotAnnotationView else { continue }
            let avCenter = CGPoint(x: av.frame.midX, y: av.frame.midY)
            let center = convert(avCenter, from: av.superview)
            let dist = hypot(center.x - point.x, center.y - point.y)
            if dist < hoverRadius && dist < nearestDist { nearestDist = dist; nearest = av }
        }
        if nearest !== hoveredDotView {
            hoveredDotView?.isHovered = false
            nearest?.isHovered = true
            hoveredDotView = nearest
        }
    }

    private func clearDotHover() {
        hoveredDotView?.isHovered = false
        hoveredDotView = nil
    }

    private func applyDockMagnification(at point: CGPoint) {
        let sigma = magInfluenceRadius / 2.8
        let visible = annotations(in: visibleMapRect)
        for ann in visible.prefix(300) {
            guard let mkAnn = ann as? (any MKAnnotation),
                  let av = view(for: mkAnn) as? ScoutPhotoAnnotationView else { continue }
            // Keep the selected (open-popover) view pinned at max scale
            if av === selectedAnnotationView {
                applyScale(magMaxScale, to: av)
                continue
            }
            let avCenter = CGPoint(x: av.frame.midX, y: av.frame.midY)
            let center = convert(avCenter, from: av.superview)
            let dist = hypot(center.x - point.x, center.y - point.y)
            let scale: CGFloat = dist < magInfluenceRadius
                ? 1 + (magMaxScale - 1) * exp(-(dist * dist) / (2 * sigma * sigma))
                : 1
            applyScale(scale, to: av)
        }
    }

    func resetMagnification(except pinned: ScoutPhotoAnnotationView? = nil) {
        for ann in annotations {
            guard let mkAnn = ann as? (any MKAnnotation),
                  let av = view(for: mkAnn) as? ScoutPhotoAnnotationView,
                  av !== pinned else { continue }
            applyScale(1, to: av)
        }
    }

    private func applyScale(_ scale: CGFloat, to view: NSView) {
        view.wantsLayer = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        view.layer?.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        view.layer?.zPosition = scale > 1 ? (scale - 1) * 300 : 0
        CATransaction.commit()
    }
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

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        wantsLayer = true
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isHovered ? 0.5 : 1.5
        let ringWidth: CGFloat = isHovered ? 3.5 : 2.5
        let oval = NSBezierPath(ovalIn: bounds.insetBy(dx: inset, dy: inset))
        NSColor.white.withAlphaComponent(isHovered ? 1.0 : 0.9).setStroke()
        oval.lineWidth = ringWidth
        oval.stroke()
        dotColor.setFill()
        oval.fill()
    }
}

// MARK: - Photo annotation view

final class ScoutPhotoAnnotationView: MKAnnotationView {
    static let reuseID = "scoutPhoto"
    private static let imageCache = NSCache<NSURL, NSImage>()

    private let imageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size: CGFloat = 50
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

        imageView.frame = bounds
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        addSubview(imageView)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.setAffineTransform(.identity)
        layer?.zPosition = 0
    }

    func configure(imageURL: URL?) {
        loadTask?.cancel()
        imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        guard let url = imageURL else { return }
        let nsURL = url as NSURL
        if let cached = Self.imageCache.object(forKey: nsURL) {
            imageView.image = cached
            return
        }
        loadTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data),
                  !Task.isCancelled else { return }
            Self.imageCache.setObject(img, forKey: nsURL)
            await MainActor.run { self.imageView.image = img }
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
    var locations: [ScoutLocation]
    var projectPins: [(ScoutLocation, String)] = []  // (location, colorHex)
    var scrollToZoom: Bool
    var initialRegion: MKCoordinateRegion?
    var controller: ScoutMapController
    var onRegionEnd: (MKCoordinateRegion) -> Void
    var isDrawingMode: Bool = false
    var searchPolygon: [CLLocationCoordinate2D]? = nil
    var onPolygonComplete: ([CLLocationCoordinate2D]) -> Void = { _ in }
    var mapType: MKMapType = .standard
    var cyclingProvider: CyclingTileProvider? = nil
    var showPhotoAnnotations: Bool = false
    var availableLists: [LocationListData] = []
    var onSaveToList: ((ScoutLocation, LocationListData) -> Void)? = nil
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
        #if os(macOS)
        map.showsScale = true
        #endif

        if let initialRegion {
            map.setRegion(initialRegion, animated: false)
        }

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
            zoomable.photoMagnificationEnabled = showPhotoAnnotations
            zoomable.onBuildAnnotationMenu = { [weak coordinator = context.coordinator] location in
                coordinator?.buildAnnotationMenu(for: location)
            }
        }
        #endif
        // NOTE: showsUserLocation is set once in makeMap and deliberately never
        // re-asserted here. Toggling it false→true resets userTrackingMode and is
        // what repeatedly broke the "follow me" button. Leave it alone.
        if map.mapType != mapType {
            map.mapType = mapType
        }
        // When annotation style toggles, remove and re-add to force viewFor: to be called
        let coord = context.coordinator
        if coord.lastPhotoAnnotationsMode != showPhotoAnnotations {
            coord.lastPhotoAnnotationsMode = showPhotoAnnotations
            let toRecycle = map.annotations.filter { !($0 is MKUserLocation) }
            map.removeAnnotations(toRecycle)
            map.addAnnotations(toRecycle)
        }
        context.coordinator.syncAnnotations(map, locations: locations)
        context.coordinator.syncProjectPins(map, pins: projectPins)
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

        func syncAnnotations(_ map: MKMapView, locations: [ScoutLocation]) {
            let current = map.annotations.compactMap { $0 as? LocationAnnotation }
            let currentIDs = Set(current.map { $0.location.id })
            let newIDs = Set(locations.map(\.id))
            guard currentIDs != newIDs else { return }
            map.removeAnnotations(current)
            map.addAnnotations(locations.map(LocationAnnotation.init))
        }

        func syncProjectPins(_ map: MKMapView, pins: [(ScoutLocation, String)]) {
            let current = map.annotations.compactMap { $0 as? ProjectAnnotation }
            let currentIDs = Set(current.map { $0.location.id })
            let newIDs = Set(pins.map { $0.0.id })
            guard currentIDs != newIDs else { return }
            map.removeAnnotations(current)
            map.addAnnotations(pins.map { ProjectAnnotation($0.0, colorHex: $0.1) })
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
            if let zoomable = mapView as? ZoomableMapView,
               let photoView = view as? ScoutPhotoAnnotationView {
                zoomable.selectedAnnotationView = photoView
                DispatchQueue.main.async {
                    zoomable.selectedAnnotationView = photoView
                    zoomable.resetMagnification(except: photoView)
                }
            }
            if view is ScoutDotAnnotationView {
                view.wantsLayer = true
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.15)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
                view.layer?.setAffineTransform(CGAffineTransform(scaleX: 2.0, y: 2.0))
                view.layer?.zPosition = 100
                CATransaction.commit()
            }
            showPopover(for: ann.location, from: view, in: mapView)
            #endif
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            parent.selection = nil
            #if os(macOS)
            activePopover?.close()
            activePopover = nil
            if let zoomable = mapView as? ZoomableMapView {
                zoomable.selectedAnnotationView = nil
                zoomable.resetMagnification()
            }
            if view is ScoutDotAnnotationView {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
                view.layer?.setAffineTransform(.identity)
                view.layer?.zPosition = 0
                CATransaction.commit()
            }
            #endif
        }

        #if os(macOS)
        private func showPopover(for location: ScoutLocation, from annotationView: MKAnnotationView, in mapView: MKMapView) {
            activePopover?.close()
            let lists = parent.availableLists
            let saveHandler = parent.onSaveToList
            let callout = LocationCalloutView(
                location: location,
                availableLists: lists,
                onSaveToList: saveHandler.map { handler in { list in handler(location, list) } }
            )
            let vc = NSHostingController(rootView: callout)
            let height = LocationCalloutView.height(for: location, hasLists: !lists.isEmpty)
            vc.view.frame.size = NSSize(width: 420, height: height)
            let pop = NSPopover()
            pop.contentViewController = vc
            pop.contentSize = vc.view.frame.size
            pop.behavior = .transient

            // Annotation views live inside MKMapView's internal container which has its own
            // coordinate transform. Convert the dot/photo center into the map view's own
            // coordinate space so NSPopover can resolve the screen position reliably.
            let avCenter = CGPoint(x: annotationView.bounds.midX, y: annotationView.bounds.midY)
            let centerInMap = mapView.convert(avCenter, from: annotationView)
            let anchorRect = NSRect(x: centerInMap.x - 1, y: centerInMap.y - 1, width: 2, height: 2)
            pop.show(relativeTo: anchorRect, of: mapView, preferredEdge: .minY)
            activePopover = pop
        }

        // Builds an NSMenu for right-click on an annotation, with "Save to List" submenu.
        func buildAnnotationMenu(for location: ScoutLocation) -> NSMenu? {
            guard !parent.availableLists.isEmpty, let handler = parent.onSaveToList else { return nil }
            let menu = NSMenu()
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

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let ann = annotation as? LocationAnnotation {
                #if os(macOS)
                if parent.showPhotoAnnotations {
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: ScoutPhotoAnnotationView.reuseID) as? ScoutPhotoAnnotationView)
                        ?? ScoutPhotoAnnotationView(annotation: annotation, reuseIdentifier: ScoutPhotoAnnotationView.reuseID)
                    view.annotation = annotation
                    view.configure(imageURL: ann.location.images.first?.url)
                    return view
                } else {
                    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: ScoutDotAnnotationView.reuseID) as? ScoutDotAnnotationView)
                        ?? ScoutDotAnnotationView(annotation: annotation, reuseIdentifier: ScoutDotAnnotationView.reuseID)
                    view.annotation = annotation
                    view.dotColor = .systemBlue
                    return view
                }
                #else
                let id = "scoutPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = .systemBlue
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

            if let ann = annotation as? ProjectAnnotation {
                #if os(macOS)
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: ScoutDotAnnotationView.reuseID + "_project") as? ScoutDotAnnotationView)
                    ?? ScoutDotAnnotationView(annotation: annotation, reuseIdentifier: ScoutDotAnnotationView.reuseID + "_project")
                view.annotation = annotation
                view.dotColor = ann.pinColor
                return view
                #else
                let id = "projectPin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.markerTintColor = ann.pinColor
                view.canShowCallout = true
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

