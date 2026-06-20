import SwiftUI
import ScoutKit

struct PhotoGridView: View {
    let locations: [ScoutLocation]

    struct PhotoItem: Identifiable {
        let id: Int
        let image: ScoutImage
        let location: ScoutLocation
        let indexInLocation: Int
    }

    private var items: [PhotoItem] {
        var result: [PhotoItem] = []
        var counter = 0
        for loc in locations {
            for (i, img) in loc.images.enumerated() {
                result.append(PhotoItem(id: counter, image: img, location: loc, indexInLocation: i))
                counter += 1
            }
        }
        return result
    }

    private let columns = 3
    private let gap: CGFloat = 2

    var body: some View {
        if items.isEmpty {
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
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(0..<columns, id: \.self) { col in
                            LazyVStack(spacing: gap) {
                                ForEach(items.indices.filter { $0 % columns == col }, id: \.self) { idx in
                                    MasonryCell(item: items[idx], width: colWidth)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
    }
}

private struct MasonryCell: View {
    let item: PhotoGridView.PhotoItem
    let width: CGFloat
    @State private var isHovered = false

    var body: some View {
        AsyncImage(url: item.image.url) { phase in
            switch phase {
            case .success(let img):
                img
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width)
            case .failure:
                Color.gray.opacity(0.2)
                    .frame(width: width, height: width * 0.65)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.3))
                    )
            default:
                Color.gray.opacity(0.12)
                    .frame(width: width, height: width * 0.65)
                    .overlay(ProgressView().tint(.white).controlSize(.small))
            }
        }
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
        .contentShape(Rectangle())
        .onHover { inside in
            isHovered = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture {
            PhotoViewerState.shared.show(
                images: item.location.images,
                startingAt: item.indexInLocation,
                location: item.location
            )
        }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}
