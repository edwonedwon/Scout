import SwiftUI
import ScoutKit

/// Holds the photo grid's multi-selection as a reference type. Owned by the grid via plain
/// @State (NOT @StateObject), so mutating it never re-renders the grid body — which would
/// otherwise recompute the full PhotoItem arrays on every click. Only the visible cells
/// observe it via @ObservedObject, so selecting (or shift-selecting thousands of) photos
/// repaints only what's on screen.
private final class GridSelection: ObservableObject {
    @Published var ids: Set<UUID> = []
    var anchor: UUID? = nil
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
}

struct PhotoGridView: View {
    /// A named group of locations forming one visual section in the grid.
    struct Section {
        let title: String
        let locations: [ScoutLocation]
        var color: Color? = nil
    }

    let locations: [ScoutLocation]
    var pinnedSections: [Section] = []
    /// UUID of the location (== PinnedLocationData.uuid) to scroll to and highlight.
    var highlightedLocationID: UUID? = nil
    /// When set, the grid scrolls this location to the top. Used to jump to the photos
    /// nearest the map's current location when switching from map to grid.
    var scrollTargetID: UUID? = nil
    var onClearSearchResults: (() -> Void)? = nil
    /// Called with the location UUID when the user taps a cell (before the carousel opens).
    var onSelectLocation: ((UUID) -> Void)? = nil
    /// Called on double-tap. ContentView uses this to open the carousel.
    var onDoubleSelectLocation: ((UUID) -> Void)? = nil
    /// Called with selected UUIDs when "Add to List" is chosen from the grid context menu.
    var onMoveToList: (([UUID]) -> Void)? = nil
    /// Called with selected UUIDs when "R" is pressed — rotate 90° counter-clockwise.
    var onRotate: (([UUID]) -> Void)? = nil
    /// Returns the original file path for a pinned location UUID (for Reveal in Finder).
    var originalFilePath: ((UUID) -> String?)? = nil

    struct PhotoItem: Identifiable {
        /// Stable UUID from the location — survives grid rebuilds so ScrollView can anchor.
        var id: UUID { location.id }
        let image: ScoutImage
        let location: ScoutLocation
        let indexInLocation: Int
        /// True for saved pins — enables drag-to-sidebar. False for search results.
        var isPinned: Bool = false
    }

    private func makeItems(from locs: [ScoutLocation], isPinned: Bool = false) -> [PhotoItem] {
        locs.compactMap { loc in
            guard let img = loc.images.first else { return nil }
            return PhotoItem(image: img, location: loc, indexInLocation: 0, isPinned: isPinned)
        }
    }

    private var searchItems: [PhotoItem] { makeItems(from: locations) }
    private var sectionItems: [(title: String, color: Color?, items: [PhotoItem])] {
        pinnedSections.map { section in
            (section.title, section.color, makeItems(from: section.locations, isPinned: true))
        }
    }
    private var allPinnedItems: [PhotoItem] { sectionItems.flatMap(\.items) }
    private var hasAny: Bool { !searchItems.isEmpty || !allPinnedItems.isEmpty }

    @State private var columns = 3
    // Plain @State so selection changes don't re-run the body (see GridSelection docs).
    @State private var gridSelection = GridSelection()
    @State private var scrollPositionID: UUID? = nil
    private let gap: CGFloat = 2

    var body: some View {
        if !hasAny {
            ContentUnavailableView(
                "No Photos",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Search for locations to see their photos here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        } else {
            GeometryReader { geo in
                let colWidth = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sectionItems.enumerated()), id: \.offset) { _, pair in
                            if !pair.items.isEmpty {
                                sectionHeader(pair.title, color: pair.color)
                                masonryGrid(items: pair.items, colWidth: colWidth,
                                            allItems: allPinnedItems + searchItems)
                            }
                        }
                        if !searchItems.isEmpty {
                            HStack {
                                sectionHeader("Search Results")
                                Spacer()
                                if let onClearSearchResults {
                                    Button(action: onClearSearchResults) {
                                        Label("Clear", systemImage: "xmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.trailing, 10)
                                }
                            }
                            masonryGrid(items: searchItems, colWidth: colWidth,
                                        allItems: allPinnedItems + searchItems)
                        }
                    }
                    .padding(.bottom, 44)
                }
                // Tracks the topmost visible item UUID so the scroll position
                // survives grid rebuilds (e.g. after a drag-drop into a list).
                .scrollPosition(id: $scrollPositionID, anchor: .top)
                .overlay(alignment: .bottom) {
                    GridSizeSlider(columns: $columns)
                }
                // Jump to a requested location (e.g. nearest the map's zoomed area). Deferred
                // so the grid — often just made visible — has laid out before we scroll.
                .onChange(of: scrollTargetID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async { scrollPositionID = id }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            // Hidden R-key button: rotate the current selection 90° counter-clockwise.
            .background {
                Button("") {
                    guard !gridSelection.ids.isEmpty else { return }
                    onRotate?(Array(gridSelection.ids))
                }
                .keyboardShortcut("r", modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
            }
        }
    }

    private func sectionHeader(_ title: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .padding(.horizontal, 10)
            if let color {
                color
                    .frame(maxWidth: .infinity)
                    .frame(height: 2)
                    .opacity(0.6)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    /// Split items into column buckets once so LazyVStack bodies never re-filter on scroll.
    private func columnBuckets(_ items: [PhotoItem]) -> [[PhotoItem]] {
        var buckets = Array(repeating: [PhotoItem](), count: max(columns, 1))
        for (i, item) in items.enumerated() { buckets[i % columns].append(item) }
        return buckets
    }

    private func masonryGrid(items: [PhotoItem], colWidth: CGFloat,
                              allItems: [PhotoItem]) -> some View {
        let buckets = columnBuckets(items)
        return HStack(alignment: .top, spacing: gap) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: gap) {
                    ForEach(buckets[col]) { item in
                        MasonryCell(
                            item: item,
                            width: colWidth,
                            isHighlighted: highlightedLocationID == item.location.id,
                            selection: gridSelection,
                            onTap: { selectItem(item, allItems: allItems) },
                            onDoubleTap: { openCarousel(from: item, universe: allItems) },
                            originalFilePath: item.isPinned ? originalFilePath?(item.location.id) : nil,
                            onMoveToList: onMoveToList
                        )
                        .id(item.id)
                    }
                }
            }
        }
    }

    private func selectItem(_ item: PhotoItem, allItems: [PhotoItem]) {
        let id = item.location.id
        #if os(macOS)
        let shift = NSEvent.modifierFlags.contains(.shift)
        let option = NSEvent.modifierFlags.contains(.option)
        #else
        // iOS has no keyboard modifiers during a tap; selection is single-tap only.
        let shift = false
        let option = false
        #endif

        if option {
            // Option: toggle this item in/out of a disparate selection.
            if gridSelection.ids.contains(id) { gridSelection.ids.remove(id) } else { gridSelection.ids.insert(id) }
            gridSelection.anchor = id
        } else if shift, let anchor = gridSelection.anchor {
            // Shift: range select from anchor to this item in display order.
            let ids = allItems.map(\.location.id)
            if let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
                let range = ids[min(a,b)...max(a,b)]
                gridSelection.ids = Set(range)
            }
        } else {
            // Plain click: single select.
            gridSelection.ids = [id]
            gridSelection.anchor = id
        }
        onSelectLocation?(id)
    }

    private func openCarousel(from item: PhotoItem, universe: [PhotoItem]) {
        onSelectLocation?(item.location.id)
        // If ContentView provided a double-tap handler (for stack-aware carousel), use it.
        if item.isPinned, let handler = onDoubleSelectLocation {
            handler(item.location.id)
            return
        }
        var seen = Set<UUID>()
        let all = universe.compactMap { i -> ScoutLocation? in
            guard seen.insert(i.location.id).inserted else { return nil }
            return i.location
        }
        let carouselImages = item.location.fullResImages.isEmpty ? item.location.images : item.location.fullResImages
        PhotoViewerState.shared.show(
            images: carouselImages,
            startingAt: item.indexInLocation,
            location: item.location,
            allLocations: all
        )
    }
}

private struct MasonryCell: View {
    let item: PhotoGridView.PhotoItem
    let width: CGFloat
    var isHighlighted: Bool = false
    @ObservedObject var selection: GridSelection
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var originalFilePath: String? = nil
    var onMoveToList: (([UUID]) -> Void)? = nil
    @State private var isHovered = false

    private var isSelected: Bool { selection.contains(item.location.id) }

    /// Resolves the UUIDs an action should target: the whole multi-selection if this item
    /// is part of it, otherwise just this item. Evaluated at action time so it's always current.
    private func actionIDs() -> [UUID] {
        selection.contains(item.location.id) && selection.ids.count > 1
            ? Array(selection.ids)
            : [item.location.id]
    }

    private func dragProvider() -> NSItemProvider {
        let ids = actionIDs()
        let payload = ids.count == 1
            ? "photo:\(ids[0].uuidString)"
            : "photos:\(ids.map(\.uuidString).joined(separator: ","))"
        return NSItemProvider(object: payload as NSString)
    }

    var body: some View {
        GooglePhotoImage(url: item.image.url, rotationQuarterTurns: item.image.rotationQuarterTurns) {
            Color.gray.opacity(0.12)
                .frame(width: width, height: width * 0.65)
                .overlay(ProgressView().tint(.white).controlSize(.small))
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: width)
        .overlay(alignment: .bottomLeading) {
            if isHovered {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 44)
                .overlay(alignment: .bottomLeading) {
                    Text(item.location.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 5)
                }
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.22))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            } else if isHighlighted {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            #if os(macOS)
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            #endif
        }
        .onTapGesture(count: 2) { onDoubleTap?() }
        .onTapGesture { onTap?() }
        .if(item.isPinned) { view in
            view.onDrag(dragProvider, preview: {
                if let url = item.image.url {
                    DragThumbnail(url: url)
                } else {
                    Color.gray.opacity(0.25).frame(width: 72, height: 72)
                }
            })
        }
        .contextMenu {
            if item.isPinned, let onMoveToList {
                Button { onMoveToList(actionIDs()) } label: {
                    Label("Add to List…", systemImage: "arrow.right.square")
                }
            }
            if item.isPinned { Divider() }
            #if os(macOS)
            if let path = originalFilePath {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }
}

/// Floating slider pinned to the bottom of the photo grid for adjusting column count.
private struct GridSizeSlider: View {
    @Binding var columns: Int
    @State private var isHovered = false
    private let minCols = 1
    private let maxCols = 8

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Slider(
                value: Binding(
                    get: { Double(maxCols + 1 - columns) },
                    set: { columns = maxCols + 1 - Int($0.rounded()) }
                ),
                in: Double(minCols)...Double(maxCols),
                step: 1
            )
            .controlSize(.small)
            .tint(.white.opacity(0.6))
            Image(systemName: "photo")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(isHovered ? 1 : 0.6))
        .clipShape(Capsule())
        .padding(.bottom, 10)
        .frame(maxWidth: 220)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

/// Drag preview for a photo grid cell.
/// Reads synchronously from PhotoLoader's NSCache so the image is available
/// immediately — drag previews don't trigger .onAppear, so async loaders show
/// a gray placeholder on the first drag.
private struct DragThumbnail: View {
    let url: URL
    var body: some View {
        Group {
            if let img = PhotoLoader.cached(url) {
                #if os(macOS)
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #else
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                #endif
            } else {
                Color.gray.opacity(0.25)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .opacity(0.72)
    }
}

private extension View {
    @ViewBuilder func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

#if DEBUG
#Preview("Photo grid") {
    PhotoGridView(
        locations: [.preview],
        pinnedSections: [PhotoGridView.Section(title: "Test Project", locations: [.preview])]
    )
    .frame(width: 700, height: 520)
}
#endif
