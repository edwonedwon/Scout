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
        // Only act when the map exists AND is actually following. Note the explicit unwrap:
        // `mapView?.userTrackingMode != .none` would compare the OPTIONAL against `nil`
        // (Optional.none), not against MKUserTrackingMode.none — so it never checked the mode.
        if let mode = mapView?.userTrackingMode, mode != .none {
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
extension NSColor {
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



// MARK: - Representable

struct ScoutMapView {
    @Binding var selection: ScoutLocation?
    /// THE shared selection store (sidebar + grid + map). Option-clicking pins writes here, and
    /// a Combine subscription in the Coordinator reflects changes made in the OTHER views back
    /// onto the map's pin rings — without re-running ContentView's body.
    var multiSelection: SelectionStore
    var locations: [ScoutLocation]
    var projectPins: [(ScoutLocation, String)] = []  // (location, colorHex)
    /// Bumped by the host only when `projectPins` actually changes, so `updateMap` can skip
    /// the O(n) map + hash of thousands of pins on unrelated re-renders (selection, hover…).
    var projectPinsVersion: Int = 0
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
    var availableLists: [ListVM] = []
    var onSaveToList: ((ScoutLocation, ListVM) -> Void)? = nil
    /// Right-click "Move N photos to list…" on a multi-selection — opens the move picker.
    var onMoveSelectionToList: (() -> Void)? = nil
    /// Right-click "Reveal in List" — expand & scroll to this pin in the sidebar.
    var onRevealInList: ((ScoutLocation) -> Void)? = nil
    /// Right-click reveal/flag/delete handlers for a saved pin (shared pin menu).
    var onRevealInGrid: ((ScoutLocation) -> Void)? = nil
    var onToggleFlagLocation: ((ScoutLocation) -> Void)? = nil
    var onDeleteLocation: ((ScoutLocation) -> Void)? = nil
    /// Returns the on-disk original-file path for a location (for "Reveal in Finder"), or nil.
    var onOriginalFilePath: ((ScoutLocation) -> String?)? = nil
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
            context.coordinator.wireSelection(store: multiSelection, mapView: map)
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
            zoomable.onBuildAnnotationMenu = { [weak coordinator = context.coordinator] location, isProjectPin in
                coordinator?.buildAnnotationMenu(for: location, isProjectPin: isProjectPin)
            }
            zoomable.onMultiSelectionChanged = { ids in
                // Write the shared store synchronously. The store's publisher then notifies the
                // sidebar/grid (which observe it). The Coordinator's own subscription also fires,
                // but reconcileSelection is a no-op because the view's multiSelectedIDs already
                // equals `ids` (set in toggleMultiSelect before this). Synchronous is safe:
                // mouse events never fire during a SwiftUI view update.
                multiSelection.ids = ids
            }
            // Reconcile rings against the shared store on any re-render (covers a render that
            // lands after an external change the Combine sink hasn't processed yet).
            context.coordinator.reconcileSelection(multiSelection.ids, on: zoomable)
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
        // Only rebuild the (large) project-pin array + diff when the version actually changed.
        // This keeps unrelated re-renders (selection, hover, typing) off the O(n) path.
        if coord.lastProjectPinsVersion != projectPinsVersion {
            coord.lastProjectPinsVersion = projectPinsVersion
            context.coordinator.syncAnnotations(map, desired: projectPins.map { ($0.0, $0.1) }, projectPins: true)
        }
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
        var lastProjectPinsVersion: Int = -1

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
                hasher.combine(loc.isFlagged)
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
            let desiredMap: [UUID: (ScoutLocation, String?)] = Dictionary(
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
                    // Replace (so viewFor: re-runs) when the tint OR the flagged state changed.
                    if existing.tintHex != tint || existing.location.isFlagged != loc.isFlagged {
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
        private var selectionCancellable: AnyCancellable?
        #endif

        /// Subscribes to the shared selection store so a selection made in the sidebar or photo
        /// grid is mirrored onto the map's pin rings — imperatively, without re-running any
        /// SwiftUI body (ContentView owns the store via plain @State, so it never re-renders the
        /// map on selection change; this subscription is what keeps the map in sync).
        func wireSelection(store: SelectionStore, mapView: MKMapView) {
            #if os(macOS)
            selectionCancellable = store.$ids
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak mapView] ids in
                    guard let self, let map = mapView as? ZoomableMapView else { return }
                    self.reconcileSelection(ids, on: map)
                }
            #endif
        }

        /// Brings the map view's working selection set + pin rings in line with `ids`.
        /// Only touches the pins whose membership actually changed, so it's cheap.
        #if os(macOS)
        func reconcileSelection(_ ids: Set<UUID>, on map: ZoomableMapView) {
            // Only pin uuids matter to the map; folder uuids in the set are ignored naturally
            // (no annotation has that id). Compare against the view's current working set.
            guard map.multiSelectedIDs != ids else { return }
            let changed = map.multiSelectedIDs.symmetricDifference(ids)
            map.multiSelectedIDs = ids
            for ann in map.annotations.compactMap({ $0 as? LocationAnnotation })
            where changed.contains(ann.location.id) {
                map.applySelectionRing(to: ann, selected: ids.contains(ann.location.id))
            }
        }
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
            #if os(macOS)
            // While an option-click multi-selection is active, NEVER show the single-pin
            // popover or hijack parent.selection. This selection can be a stray re-selection
            // from syncSelection (parent.selection is cleared only asynchronously via
            // didDeselect, so a re-render can re-select the previously-open pin). Undo it
            // immediately and bail — the user is building a batch, not inspecting one pin.
            // Check the view's own synchronous multiSelectedIDs (the binding lags a frame).
            if let zoomable = mapView as? ZoomableMapView, !zoomable.multiSelectedIDs.isEmpty {
                mapView.deselectAnnotation(ann, animated: false)
                return
            }
            #endif
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
                // MapKit fires didDeselect asynchronously, so it can land AFTER an option-click
                // has already folded this pin into the multi-selection and rung it blue. Photo
                // pins reuse `borderColor` for both the single-select highlight AND the
                // multi-select ring, so blindly clearing it here wipes the ring of a pin that's
                // still selected — the "blue frame randomly disappears" bug. Only clear when the
                // pin is genuinely out of the multi-selection. (Dots track multi-select via the
                // separate isMultiSelected flag, so resetting dotColor never affects their ring.)
                let inMultiSelect = (mapView as? ZoomableMapView)?.multiSelectedIDs.contains(ann.location.id) ?? false
                if let photo = view as? ScoutPhotoAnnotationView {
                    photo.borderColor = inMultiSelect ? .systemBlue : .clear
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
            // Never show the popover during an active option-click multi-selection.
            if let zoomable = mapView as? ZoomableMapView, !zoomable.multiSelectedIDs.isEmpty { return }
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

        /// Right-click menu for a map annotation.
        /// - Multi-selection (≥2): the "Move N photos to list…" action (unchanged).
        /// - A SAVED pin: the SHARED pin menu (Flag / Reveal in Finder / Reveal in Photo Grid /
        ///   Reveal in List / Delete) — identical to the sidebar & grid menus.
        /// - A search-result pin (not saved): "Save to List".
        func buildAnnotationMenu(for location: ScoutLocation, isProjectPin: Bool) -> NSMenu? {
            // Multi-selection: one item that opens the move picker for all selected pins.
            let selectionCount = parent.multiSelection.ids.count
            if selectionCount >= 2, let moveSelection = parent.onMoveSelectionToList {
                let menu = NSMenu()
                let act = MenuAction { moveSelection() }
                menuActions.append(act)
                let item = NSMenuItem(title: "Move \(selectionCount) photos to list…",
                                      action: #selector(MenuAction.invoke), keyEquivalent: "")
                item.target = act
                menu.addItem(item)
                return menu
            }

            // Saved pin → shared pin menu.
            if isProjectPin {
                let path = parent.onOriginalFilePath?(location)
                let actions = PinMenuActions(
                    isFlagged: location.isFlagged,
                    toggleFlag: { [weak self] in self?.parent.onToggleFlagLocation?(location) },
                    revealInFinder: path.map { p in { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") } },
                    revealInList: parent.onRevealInList.map { f in { f(location) } },
                    revealInGrid: parent.onRevealInGrid.map { f in { f(location) } },
                    revealOnMap: nil,
                    delete: { [weak self] in self?.parent.onDeleteLocation?(location) }
                )
                return nsMenu(from: pinMenuEntries(.map, actions))
            }

            // Search-result pin → Save to List.
            if !parent.availableLists.isEmpty, let handler = parent.onSaveToList {
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
            return nil
        }

        /// Renders shared `PinMenuEntry`s as an NSMenu (the map's AppKit equivalent of the
        /// SwiftUI `pinContextMenuItems`). Retains each action in `menuActions`.
        private func nsMenu(from entries: [PinMenuEntry]) -> NSMenu {
            let menu = NSMenu()
            for entry in entries {
                if entry.separatorBefore { menu.addItem(.separator()) }
                let act = MenuAction(entry.action)
                menuActions.append(act)
                let item = NSMenuItem(title: entry.title,
                                      action: #selector(MenuAction.invoke), keyEquivalent: "")
                item.target = act
                menu.addItem(item)
            }
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
                    view.isFlagged = ann.location.isFlagged
                    // Flagged photos float above other photos/pins (below hover=100 and the
                    // user-location dot=10_000). displayPriority keeps them from being culled.
                    view.layer?.zPosition = ann.location.isFlagged ? 50 : 0
                    view.displayPriority = ann.location.isFlagged ? .required : .defaultHigh
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
                    view.isFlagged = ann.location.isFlagged
                    view.layer?.zPosition = ann.location.isFlagged ? 50 : 0
                    view.displayPriority = ann.location.isFlagged ? .required : .defaultHigh
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

