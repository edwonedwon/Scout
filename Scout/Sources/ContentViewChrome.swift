import SwiftUI
import MapKit
import ScoutKit

struct SavedRegion: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var polygon: [CLLocationCoordinate2D]
    var isActive: Bool

    init(name: String, polygon: [CLLocationCoordinate2D], isActive: Bool) {
        self.name = name
        self.polygon = polygon
        self.isActive = isActive
    }

    static func == (lhs: SavedRegion, rhs: SavedRegion) -> Bool {
        lhs.id == rhs.id && lhs.isActive == rhs.isActive
    }

    // CLLocationCoordinate2D isn't Codable, so the polygon is stored as a flat
    // [lat, lng, lat, lng, …] array for persistence.
    enum CodingKeys: String, CodingKey { case id, name, polygon, isActive }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        let flat = (try? c.decode([Double].self, forKey: .polygon)) ?? []
        var coords: [CLLocationCoordinate2D] = []
        var i = 0
        while i + 1 < flat.count {
            coords.append(.init(latitude: flat[i], longitude: flat[i + 1]))
            i += 2
        }
        polygon = coords
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isActive, forKey: .isActive)
        try c.encode(polygon.flatMap { [$0.latitude, $0.longitude] }, forKey: .polygon)
    }
}

// MARK: - Region toggle chip

struct RegionChip: View {
    let name: String
    let isActive: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(name)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isActive ? .white : .primary)
                .lineLimit(1)
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(isActive ? Color.blue : Color.primary.opacity(0.08),
                    in: Capsule())
        .overlay(Capsule().stroke(isActive ? Color.clear : Color.primary.opacity(0.15), lineWidth: 0.5))
        .onTapGesture(perform: onToggle)
    }
}

/// A thin draggable divider between the left sidebar and the center panel. Hovering shows
/// the horizontal-resize cursor (macOS); dragging adjusts the bound width within [min, max].
struct SidebarResizeHandle: View {
    /// Current width (the live value during a drag, or the persisted value at rest).
    let width: Double
    let minWidth: Double
    let maxWidth: Double
    /// Fired every drag tick with the new live width — drives a plain @State, no persistence.
    let onLiveChange: (Double) -> Void
    /// Fired once on drag end with the final width — this is where it's persisted.
    let onCommit: (Double) -> Void
    @State private var dragStartWidth: Double? = nil
    @State private var hovering = false

    /// Width of the grab zone. The visible separator is 1px, centered inside this — the rest is an
    /// easy-to-hit transparent margin on each side.
    private let hitWidth: CGFloat = 12

    private func clamp(_ w: Double) -> Double { min(max(w, minWidth), maxWidth) }

    var body: some View {
        // A real-width view (not a 1px Divider with a floating overlay): SwiftUI only delivers
        // hover/drag events within a view's actual layout frame, so the handle must genuinely
        // occupy the full grab width for the whole zone to be draggable. The thin separator line
        // is drawn centered so it still looks like a 1px divider.
        ZStack {
            Color.clear.contentShape(Rectangle())
            Divider().frame(width: 1)
        }
        .frame(width: hitWidth)
        .frame(maxHeight: .infinity)
        #if os(macOS)
        // Balance push/pop with a flag so a missed exit event can't leave a stuck resize cursor.
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        #endif
        // Global coordinate space: the handle moves as the sidebar resizes, so a .local
        // translation would be measured against a frame that's shifting under the cursor — that
        // feedback loop makes the drag oscillate. Global (screen) coordinates are stable.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = dragStartWidth ?? width
                    if dragStartWidth == nil { dragStartWidth = width }
                    onLiveChange(clamp(base + value.translation.width))
                }
                .onEnded { value in
                    let base = dragStartWidth ?? width
                    onCommit(clamp(base + value.translation.width))
                    dragStartWidth = nil
                }
        )
    }
}

/// The one card used to show a location everywhere — sidebar search results and
/// saved-list rows alike. Purely visual and driven by a `ScoutLocation`; callers
/// attach their own behavior (drag, drop, tap, context menus) around it.
struct LocationRow: View {
    let location: ScoutLocation
    var showsPhotos: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsPhotos, !location.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(location.images) { image in
                            if let url = image.url {
                                GooglePhotoImage(url: url) {
                                    Color.secondary.opacity(0.1)
                                        .overlay(ProgressView().controlSize(.mini))
                                }
                                .scaledToFill()
                                .frame(width: 100, height: 70)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 74)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }

            Text(location.name)
                .font(.headline)
                .lineLimit(1)

            if !location.description.isEmpty {
                Text(location.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack {
                Label(location.status.rawValue, systemImage: location.status.icon)
                    .font(.caption2)
                    .foregroundStyle(location.status.color)
                Spacer()
                if let url = location.googleMapsURL {
                    Link(destination: url) {
                        Image(systemName: "map").font(.caption)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

extension View {
    /// Floating map-control chrome: material fill, soft shadow, fixed square.
    func mapControlChrome(diameter: CGFloat = 36, circle: Bool = true) -> some View {
        frame(width: diameter, height: diameter)
            .background(.regularMaterial, in: circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
    }
}

extension LocationStatus {
    var icon: String {
        switch self {
        case .scouted: "mappin.circle"
        case .shortlisted: "star.circle"
        case .approved: "checkmark.circle.fill"
        case .rejected: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .scouted: .secondary
        case .shortlisted: .orange
        case .approved: .green
        case .rejected: .red
        }
    }
}

// MARK: - Right panel tabs

enum RightPanelTab: String, CaseIterable, Identifiable {
    case ai, google, foursquare, flickr, wikimedia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ai:          "AI"
        case .google:      "Google"
        case .foursquare:  "4Square"
        case .flickr:      "Flickr"
        case .wikimedia:   "Wiki"
        }
    }

    var icon: String {
        switch self {
        case .ai:          "sparkles"
        case .google:      "map"
        case .foursquare:  "mappin.and.ellipse"
        case .flickr:      "camera"
        case .wikimedia:   "globe"
        }
    }

    var placeholder: String {
        switch self {
        case .ai:          ""
        case .google:      "Search Google Maps…"
        case .foursquare:  "Search Foursquare…"
        case .flickr:      "Search Flickr photos…"
        case .wikimedia:   "Search Wikimedia Commons…"
        }
    }

    var emptyHint: String {
        switch self {
        case .ai:          "Ask AI Scout for locations"
        case .google:      "Search Google Maps above"
        case .foursquare:  "Search Foursquare above"
        case .flickr:      "Search for geotagged Flickr photos"
        case .wikimedia:   "Search for geotagged Commons photos"
        }
    }

    var emptyIcon: String {
        switch self {
        case .ai:         "sparkles"
        case .google:     "mappin.slash"
        case .foursquare: "mappin.and.ellipse"
        case .flickr:     "camera"
        case .wikimedia:  "globe"
        }
    }
}

// MARK: - View mode

enum ViewMode: CaseIterable {
    case map, photos, script
}

// MARK: - Map style
