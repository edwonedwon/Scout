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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(items) { item in
                        PhotoCell(item: item)
                    }
                }
                .padding(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        }
    }
}

private struct PhotoCell: View {
    let item: PhotoGridView.PhotoItem
    @State private var isHovered = false

    var body: some View {
        AsyncImage(url: item.image.url) { phase in
            switch phase {
            case .success(let img):
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                Color.gray.opacity(0.2)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.3))
                    )
            default:
                Color.gray.opacity(0.15)
                    .overlay(ProgressView().tint(.white).controlSize(.small))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .overlay(alignment: .bottom) {
            if isHovered {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 48)
                    .overlay(alignment: .bottomLeading) {
                        Text(item.location.name)
                            .font(.caption2.weight(.medium))
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
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

