import SwiftUI
import MapKit
import ScoutKit
import CoreVideo
import Combine
#if os(macOS)
import AppKit
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
    var onBuildAnnotationMenu: ((ScoutLocation, Bool) -> NSMenu?)?
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
        // Use the SAME reliable spatial lookup as left-click (hover/pinUnderCursor). The old
        // hitTest()+walk-up was unreliable on MapKit annotation views — it only occasionally
        // landed on the annotation, which is why the menu rarely appeared.
        applyHover(at: pt)
        if let ann = pinUnderCursor?.annotation as? LocationAnnotation,
           let menu = onBuildAnnotationMenu?(ann.location, ann.isProjectPin) {
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
        // The cursor can be over a floating overlay (e.g. the user-location button) or off
        // the map entirely, in which case `convert` returns an out-of-range coordinate.
        // Anchoring the zoom to that garbage produces an invalid region (lat > 90), which
        // MapKit rejects with "Invalid Region". Bail instead of zooming to nonsense.
        guard CLLocationCoordinate2DIsValid(cursor) else { return }

        let current = region
        let newLatDelta = min(max(current.span.latitudeDelta  * factor, 0.0005), 160)
        let newLngDelta = min(max(current.span.longitudeDelta * factor, 0.0005), 160)

        // Fractional position of cursor within the current span (coordinate-system agnostic).
        // Keep that fraction constant → cursor geographic point stays under the cursor.
        let latFrac = (cursor.latitude  - current.center.latitude)  / current.span.latitudeDelta
        let lngFrac = (cursor.longitude - current.center.longitude) / current.span.longitudeDelta

        // Clamp the resulting center so the region edges stay inside MapKit's valid range,
        // belt-and-suspenders against any drift in the math above.
        let halfLat = newLatDelta / 2
        let newLat = min(max(cursor.latitude  - latFrac * newLatDelta, -90 + halfLat), 90 - halfLat)
        let newLng = min(max(cursor.longitude - lngFrac * newLngDelta, -180), 180)

        let proposed = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: newLat, longitude: newLng),
            span: MKCoordinateSpan(latitudeDelta: newLatDelta, longitudeDelta: newLngDelta)
        )
        guard CLLocationCoordinate2DIsValid(proposed.center), newLat.isFinite, newLng.isFinite else { return }
        setRegion(proposed, animated: false)
    }

    deinit { if let link = cvLink { CVDisplayLinkStop(link) } }

    // MARK: - Dot hover

    private var magTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = magTrackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        magTrackingArea = t
    }

    // Hover throttle: applyHover runs a spatial query + view lookups; mouseMoved fires at
    // 60-120 Hz, so cap it to ~30 Hz with a trailing update so the final resting position
    // is never dropped. Hover is purely cosmetic, so coalescing intermediate moves is safe.
    private var hoverThrottleUntil: TimeInterval = 0
    private var pendingHoverPoint: CGPoint?
    private var hoverScheduled = false

    // MKMapView's internal feature/label views push an I-beam over the map surface; force the
    // arrow back so the map reads as a clickable surface, not selectable text. (Drawing mode keeps
    // its own crosshair.) Handled both via the tracking area's cursorUpdate and on every move.
    override func cursorUpdate(with event: NSEvent) {
        if isDrawingMode { return }
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isDrawingMode else { return }
        NSCursor.arrow.set()
        let pt = convert(event.locationInWindow, from: nil)
        let now = CACurrentMediaTime()
        if now >= hoverThrottleUntil {
            hoverThrottleUntil = now + 0.033
            applyHover(at: pt)
            return
        }
        pendingHoverPoint = pt
        guard !hoverScheduled else { return }
        hoverScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (hoverThrottleUntil - now)) { [weak self] in
            guard let self else { return }
            self.hoverScheduled = false
            guard let p = self.pendingHoverPoint else { return }
            self.pendingHoverPoint = nil
            self.hoverThrottleUntil = CACurrentMediaTime() + 0.033
            self.applyHover(at: p)
        }
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
                // Restore the resting z — flagged photos stay floated above the rest.
                photo.layer?.zPosition = photo.isFlagged ? 50 : 0
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
    /// Flagged (favorite filming) location — draws a small red badge at the corner.
    var isFlagged: Bool = false {
        didSet { guard oldValue != isFlagged else { return }; needsDisplay = true }
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

        // Flag badge: small red dot at the top-left, kept inside bounds so it isn't clipped.
        if isFlagged {
            let bs = bounds.width * 0.55
            let badge = CGRect(x: bounds.minX, y: bounds.minY, width: bs, height: bs)
            let path = NSBezierPath(ovalIn: badge)
            NSColor.systemRed.setFill(); path.fill()
            NSColor.white.setStroke(); path.lineWidth = max(bs * 0.18, 1); path.stroke()
        }
    }
}

// MARK: - Photo annotation view

final class ScoutPhotoAnnotationView: MKAnnotationView {
    static let reuseID = "scoutPhoto"

    /// CALayer used instead of NSImageView so we get contentsGravity = .resizeAspectFill
    /// (fill+crop) which NSImageView cannot do natively.
    private let photoLayer = CALayer()
    private let flagBadge = CALayer()
    private var loadTask: Task<Void, Never>?
    private var currentScale: CGFloat = 1.0

    /// Red badge marking a flagged (favorite filming) location.
    var isFlagged: Bool = false {
        didSet { guard oldValue != isFlagged else { return }; flagBadge.isHidden = !isFlagged }
    }
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

        // Flag badge: red dot in the TOP-LEFT corner, sitting ON TOP of the photo frame.
        // Kept fully inside the view bounds — MapKit clips annotation views to their bounds, so
        // any overflow gets cropped (which is what cut the old badge). zPosition floats it above
        // the photo + border.
        let bs: CGFloat = 15
        flagBadge.frame = CGRect(x: 1, y: 1, width: bs, height: bs)
        flagBadge.backgroundColor = NSColor.systemRed.cgColor
        flagBadge.cornerRadius = bs / 2
        flagBadge.borderColor = NSColor.white.cgColor
        flagBadge.borderWidth = 2
        flagBadge.zPosition = 100
        flagBadge.isHidden = true
        layer?.addSublayer(flagBadge)
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
        let bs = 15 * ratio
        flagBadge.frame = CGRect(x: ratio, y: ratio, width: bs, height: bs)
        flagBadge.cornerRadius = bs / 2
        applyBorder()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        layer?.setAffineTransform(.identity)
        layer?.zPosition = 0
        isHovered = false
        isFlagged = false
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
