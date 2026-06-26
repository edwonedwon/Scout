import SwiftUI
import ScoutKit

struct PhotoGridView: View {
    /// THE shared selection store (sidebar + grid + map). Passed in by ContentView so a
    /// selection made here shows up in the sidebar and on the map, and vice-versa.
    ///
    /// Observed at the grid level so the grid reliably repaints when the selection changes —
    /// including changes made on the MAP. (Relying only on each cell's @ObservedObject failed
    /// to update cells when the grid body itself never re-ran.) This is cheap because the
    /// expensive display model is memoized by `inputSignature`, which deliberately does NOT
    /// include the selection — so a selection change re-evaluates only the (lazy) view tree,
    /// never `rebuildModel()`/the PhotoItem arrays.
    @ObservedObject var selection: SelectionStore
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

    /// One section's pre-bucketed display data. Built once per input/column change so the
    /// scroll body never re-derives PhotoItems while scrolling.
    private struct SectionModel: Identifiable {
        let id: Int
        let title: String
        let color: Color?
        let buckets: [[PhotoItem]]
    }
    /// The whole grid's memoized display model. Rebuilt only when `inputSignature` changes
    /// (data or column count), NOT on every scroll tick / highlight change. Without this the
    /// body rebuilt thousands of structs + two array concatenations per scroll frame.
    private struct GridModel {
        var sections: [SectionModel] = []
        var searchBuckets: [[PhotoItem]] = []
        var hasSearch = false
        /// Sequential (display) order of every item — used for shift-range selection.
        var allItems: [PhotoItem] = []
        var hasAny: Bool { !sections.isEmpty || hasSearch }
    }

    @State private var columns = 3
    @State private var scrollPositionID: UUID? = nil
    @State private var model = GridModel()
    private let gap: CGFloat = 2

    /// Cheap O(sections) fingerprint of the inputs + column count. Changing it rebuilds the
    /// memoized model; a pure scroll (which doesn't change it) reuses the built model.
    private var inputSignature: Int {
        var h = Hasher()
        h.combine(columns)
        h.combine(locations.count)
        h.combine(locations.first?.id)
        h.combine(locations.last?.id)
        h.combine(pinnedSections.count)
        for s in pinnedSections {
            h.combine(s.title)
            h.combine(s.locations.count)
            h.combine(s.locations.first?.id)
            h.combine(s.locations.last?.id)
        }
        return h.finalize()
    }

    private func rebuildModel() {
        let cols = max(columns, 1)
        func bucketize(_ items: [PhotoItem]) -> [[PhotoItem]] {
            var b = Array(repeating: [PhotoItem](), count: cols)
            for (i, it) in items.enumerated() { b[i % cols].append(it) }
            return b
        }
        var sections: [SectionModel] = []
        var allPinned: [PhotoItem] = []
        for (i, section) in pinnedSections.enumerated() {
            let items = makeItems(from: section.locations, isPinned: true)
            guard !items.isEmpty else { continue }
            allPinned += items
            sections.append(SectionModel(id: i, title: section.title, color: section.color,
                                         buckets: bucketize(items)))
        }
        let search = makeItems(from: locations)
        model = GridModel(sections: sections,
                          searchBuckets: bucketize(search),
                          hasSearch: !search.isEmpty,
                          allItems: allPinned + search)
    }

    var body: some View {
        content
            // initial:true builds the model on first appearance; later fires only when the
            // data or column count changes — never during scroll.
            .onChange(of: inputSignature, initial: true) { _, _ in rebuildModel() }
    }

    @ViewBuilder private var content: some View {
        if !model.hasAny {
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
                        ForEach(model.sections) { section in
                            sectionHeader(section.title, color: section.color)
                            masonryGrid(buckets: section.buckets, colWidth: colWidth)
                        }
                        if model.hasSearch {
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
                            masonryGrid(buckets: model.searchBuckets, colWidth: colWidth)
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
                    guard !selection.ids.isEmpty else { return }
                    onRotate?(Array(selection.ids))
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

    private func masonryGrid(buckets: [[PhotoItem]], colWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<buckets.count, id: \.self) { col in
                LazyVStack(spacing: gap) {
                    ForEach(buckets[col]) { item in
                        MasonryCell(
                            item: item,
                            width: colWidth,
                            isHighlighted: highlightedLocationID == item.location.id,
                            selection: selection,
                            onTap: { selectItem(item) },
                            onDoubleTap: { openCarousel(from: item) },
                            originalFilePath: item.isPinned ? originalFilePath?(item.location.id) : nil,
                            onMoveToList: onMoveToList
                        )
                        .id(item.id)
                    }
                }
            }
        }
    }

    private func selectItem(_ item: PhotoItem) {
        let allItems = model.allItems
        let id = item.location.id
        // Read the modifiers snapshotted at mouse-DOWN (see ClickModifiers). Reading the live
        // NSEvent.modifierFlags here is racy: the tap handler runs on mouse-UP / deferred, by
        // which point Shift/Option may already be released — which is exactly why grid
        // multi-select kept failing.
        let (shift, option) = currentModifierFlags()

        if option {
            // Option: toggle this item in/out of a disparate selection.
            if selection.ids.contains(id) { selection.ids.remove(id) } else { selection.ids.insert(id) }
            selection.anchor = id
        } else if shift, let anchor = selection.anchor {
            // Shift: range select from anchor to this item in display order.
            let ids = allItems.map(\.location.id)
            if let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
                let range = ids[min(a,b)...max(a,b)]
                selection.ids = Set(range)
            }
        } else {
            // Plain click: single select.
            selection.ids = [id]
            selection.anchor = id
            // Only update the single highlight (and thus the sidebar scroll-to) on a PLAIN
            // click. Doing it for option/shift would churn `highlightedPinID` mid-multi-select.
            onSelectLocation?(id)
        }
    }

    private func openCarousel(from item: PhotoItem) {
        onSelectLocation?(item.location.id)
        // If ContentView provided a double-tap handler (for stack-aware carousel), use it.
        if item.isPinned, let handler = onDoubleSelectLocation {
            handler(item.location.id)
            return
        }
        var seen = Set<UUID>()
        let all = model.allItems.compactMap { i -> ScoutLocation? in
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
    @ObservedObject var selection: SelectionStore
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var originalFilePath: String? = nil
    var onMoveToList: (([UUID]) -> Void)? = nil
    @State private var isHovered = false

    private var isSelected: Bool { selection.contains(item.location.id) }

    /// Effective display aspect (width/height), accounting for 90° rotations. Falls back to a
    /// reasonable landscape ratio only when the photo hasn't been measured yet.
    private var cellAspect: CGFloat {
        let a = item.image.aspectRatio
        guard a > 0 else { return 1.0 / 0.65 }
        let turns = ((item.image.rotationQuarterTurns % 4) + 4) % 4
        return turns % 2 == 1 ? CGFloat(1.0 / a) : CGFloat(a)
    }
    /// Cell height is derived from the KNOWN aspect ratio (from the model), so it's fixed at
    /// mount — the image loads into an already-correctly-sized frame with no layout reflow.
    private var cellHeight: CGFloat { (width / cellAspect).rounded() }

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
        GooglePhotoImage(url: item.image.url,
                         rotationQuarterTurns: item.image.rotationQuarterTurns,
                         targetPixelSize: width * (NSScreen.main?.backingScaleFactor ?? 2)) {
            Color.gray.opacity(0.12)
        }
        // Fixed frame from the known aspect ratio → no reflow when the image loads. fill+clip
        // shows the whole photo (frame already matches aspect) and crops only on the rare
        // not-yet-measured fallback instead of distorting.
        .aspectRatio(contentMode: .fill)
        .frame(width: width, height: cellHeight)
        .clipped()
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
        // Single tap fires IMMEDIATELY (double-tap is a SEPARATE simultaneous gesture), so the
        // modifier keys are still held when selectItem reads them. The old sequential
        // .onTapGesture(count:2) + (count:1) made the single tap WAIT to rule out a double —
        // by the time it fired, option/shift had been released, so every click fell through to
        // plain single-select and multi-select didn't work. (Matches the sidebar's pattern.)
        .onTapGesture { onTap?() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
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
        selection: SelectionStore(),
        locations: [.preview],
        pinnedSections: [PhotoGridView.Section(title: "Test Project", locations: [.preview])]
    )
    .frame(width: 700, height: 520)
}
#endif
