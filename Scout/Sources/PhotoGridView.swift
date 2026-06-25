import SwiftUI
import ScoutKit

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
    var onClearSearchResults: (() -> Void)? = nil
    /// Called with the location UUID when the user taps a cell (before the carousel opens).
    var onSelectLocation: ((UUID) -> Void)? = nil
    /// Returns the original file path for a pinned location UUID (for Reveal in Finder).
    var originalFilePath: ((UUID) -> String?)? = nil

    struct PhotoItem: Identifiable {
        let id: Int
        let image: ScoutImage
        let location: ScoutLocation
        let indexInLocation: Int
        /// True for saved pins — enables drag-to-sidebar. False for search results.
        var isPinned: Bool = false
    }

    private func makeItems(from locs: [ScoutLocation], startID: Int = 0,
                           isPinned: Bool = false) -> [PhotoItem] {
        var result: [PhotoItem] = []
        var counter = startID
        for loc in locs {
            guard let img = loc.images.first else { counter += 1; continue }
            result.append(PhotoItem(id: counter, image: img, location: loc,
                                    indexInLocation: 0, isPinned: isPinned))
            counter += 1
        }
        return result
    }

    private var searchItems: [PhotoItem] { makeItems(from: locations, startID: 2_000_000) }
    // Build section items with non-overlapping IDs (sections use 0-based, search uses 2M+).
    private var sectionItems: [(title: String, color: Color?, items: [PhotoItem])] {
        var counter = 0
        return pinnedSections.map { section in
            let items = makeItems(from: section.locations, startID: counter, isPinned: true)
            counter += section.locations.count + 1
            return (section.title, section.color, items)
        }
    }
    private var allPinnedItems: [PhotoItem] { sectionItems.flatMap(\.items) }
    private var hasAny: Bool { !searchItems.isEmpty || !allPinnedItems.isEmpty }

    @State private var columns = 3
    @State private var selectedIDs: Set<UUID> = []
    @State private var anchorID: UUID? = nil
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
                .overlay(alignment: .bottom) {
                    GridSizeSlider(columns: $columns)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
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
                            isSelected: selectedIDs.contains(item.location.id),
                            onTap: { selectItem(item, allItems: allItems) },
                            onDoubleTap: { openCarousel(from: item, universe: allItems) },
                            dragPayload: item.isPinned ? {
                                let ids = selectedIDs.contains(item.location.id) && selectedIDs.count > 1
                                    ? Array(selectedIDs)
                                    : [item.location.id]
                                let payload = ids.count == 1
                                    ? "photo:\(ids[0].uuidString)"
                                    : "photos:\(ids.map(\.uuidString).joined(separator: ","))"
                                return NSItemProvider(object: payload as NSString)
                            } : nil,
                            originalFilePath: item.isPinned ? originalFilePath?(item.location.id) : nil
                        )
                        .id(item.id)
                    }
                }
            }
        }
    }

    private func selectItem(_ item: PhotoItem, allItems: [PhotoItem]) {
        let id = item.location.id
        let shift = NSEvent.modifierFlags.contains(.shift)
        let option = NSEvent.modifierFlags.contains(.option)

        if option {
            // Option: toggle this item in/out of a disparate selection.
            if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
            anchorID = id
        } else if shift, let anchor = anchorID {
            // Shift: range select from anchor to this item in display order.
            let ids = allItems.map(\.location.id)
            if let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
                let range = ids[min(a,b)...max(a,b)]
                selectedIDs = Set(range)
            }
        } else {
            // Plain click: single select.
            selectedIDs = [id]
            anchorID = id
        }
        onSelectLocation?(id)
    }

    private func openCarousel(from item: PhotoItem, universe: [PhotoItem]) {
        onSelectLocation?(item.location.id)
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
    var isSelected: Bool = false
    var onTap: (() -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    var dragPayload: (() -> NSItemProvider)? = nil
    var originalFilePath: String? = nil
    @State private var isHovered = false

    var body: some View {
        GooglePhotoImage(url: item.image.url) {
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
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture(count: 2) { onDoubleTap?() }
        .onTapGesture { onTap?() }
        .if(item.isPinned && dragPayload != nil) { view in
            view.onDrag(dragPayload!, preview: {
                if let url = item.image.url {
                    DragThumbnail(url: url)
                } else {
                    Color.gray.opacity(0.25).frame(width: 72, height: 72)
                }
            })
        }
        .contextMenu {
            if let path = originalFilePath {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }
            }
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
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
