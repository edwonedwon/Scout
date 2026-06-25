import SwiftUI
import ScoutKit

struct PhotoGridView: View {
    let locations: [ScoutLocation]
    var pinnedLocations: [ScoutLocation] = []
    /// UUID of the location (== PinnedLocationData.uuid) to scroll to and highlight.
    var highlightedLocationID: UUID? = nil
    var onClearSearchResults: (() -> Void)? = nil

    struct PhotoItem: Identifiable {
        let id: Int
        let image: ScoutImage
        let location: ScoutLocation
        let indexInLocation: Int
    }

    private func makeItems(from locs: [ScoutLocation], startID: Int = 0) -> [PhotoItem] {
        var result: [PhotoItem] = []
        var counter = startID
        for loc in locs {
            // Only show the first photo per location in the grid. The rest are loaded
            // lazily in the carousel when the user opens it.
            guard let img = loc.images.first else { counter += 1; continue }
            result.append(PhotoItem(id: counter, image: img, location: loc, indexInLocation: 0))
            counter += 1
        }
        return result
    }

    private var searchItems: [PhotoItem] { makeItems(from: locations) }
    private var pinnedItems: [PhotoItem] { makeItems(from: pinnedLocations, startID: 1_000_000) }
    private var hasAny: Bool { !searchItems.isEmpty || !pinnedItems.isEmpty }

    private let columns = 3
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
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !pinnedItems.isEmpty {
                                sectionHeader("Saved Pins")
                                masonryGrid(items: pinnedItems, colWidth: colWidth)
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
                                masonryGrid(items: searchItems, colWidth: colWidth)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: highlightedLocationID) { _, id in
                        guard let id,
                              let first = (pinnedItems + searchItems).first(where: { $0.location.id == id })
                        else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(first.id, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.55))
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func masonryGrid(items: [PhotoItem], colWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: gap) {
                    ForEach(items.indices.filter { $0 % columns == col }, id: \.self) { idx in
                        let item = items[idx]
                        MasonryCell(
                            item: item,
                            width: colWidth,
                            isHighlighted: highlightedLocationID == item.location.id,
                            onTap: { openCarousel(from: item) }
                        )
                        .id(item.id)
                    }
                }
            }
        }
    }

    private func openCarousel(from item: PhotoItem) {
        // Build the full ordered universe: pinned locations first, then search locations.
        // Deduplicate by id so a location that appears in both doesn't get counted twice.
        var seen = Set<UUID>()
        let all = (pinnedItems + searchItems).compactMap { i -> ScoutLocation? in
            guard seen.insert(i.location.id).inserted else { return nil }
            return i.location
        }
        PhotoViewerState.shared.show(
            images: item.location.images,
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
    var onTap: (() -> Void)? = nil
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
            if isHighlighted {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture { onTap?() }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
    }
}

#if DEBUG
#Preview("Photo grid") {
    PhotoGridView(locations: [.preview], pinnedLocations: [.preview])
        .frame(width: 700, height: 520)
}
#endif
