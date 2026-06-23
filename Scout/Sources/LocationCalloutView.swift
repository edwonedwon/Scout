import SwiftUI
import SwiftData
import ScoutKit

struct LocationCalloutView: View {
    let location: ScoutLocation
    var availableLists: [LocationListData] = []
    var onSaveToList: ((LocationListData) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photos
            if !location.images.isEmpty {
                let images = Array(location.images.prefix(8))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                            GooglePhotoImage(url: img.url) {
                                Rectangle().fill(.quaternary)
                                    .overlay(ProgressView().controlSize(.small))
                            }
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 160, height: 120)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                PhotoViewerState.shared.openedFromMap = true
                                PhotoViewerState.shared.show(images: images, startingAt: idx, location: location)
                            }
                            .cursor(.pointingHand)
                        }
                    }
                }
                .frame(height: 120)
            }

            VStack(alignment: .leading, spacing: 6) {
                // Name
                Text(location.name)
                    .font(.headline)
                    .lineLimit(2)

                // Address / description
                if !location.description.isEmpty {
                    Text(location.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                // Links
                HStack(spacing: 14) {
                    if let url = location.googleMapsURL {
                        Link(destination: url) {
                            Label("Google Maps", systemImage: "map.fill")
                                .font(.caption.weight(.medium))
                        }
                    }
                    if let url = location.sourceURL {
                        Link(destination: url) {
                            Label("Source", systemImage: "safari.fill")
                                .font(.caption.weight(.medium))
                        }
                    }
                }

                // Save to list
                if !availableLists.isEmpty, let onSave = onSaveToList {
                    Divider()
                    Menu {
                        ForEach(availableLists) { list in
                            Button {
                                onSave(list)
                            } label: {
                                Label(list.name, systemImage: "mappin.circle")
                            }
                        }
                    } label: {
                        Label("Save to List", systemImage: "folder.badge.plus")
                            .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .background(.background)
    }

    static func height(for location: ScoutLocation, hasLists: Bool = false) -> CGFloat {
        var h: CGFloat = 24  // vertical padding
        if !location.images.isEmpty { h += 120 }
        h += 28  // name
        if !location.description.isEmpty { h += 52 }
        let hasLinks = location.googleMapsURL != nil || location.sourceURL != nil
        if hasLinks { h += 28 }
        if hasLists { h += 40 }  // save to list row
        return h
    }
}

// MARK: - Cursor helper (macOS)

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        #if os(macOS)
        return self.onHover { inside in inside ? cursor.push() : NSCursor.pop() }
        #else
        return self
        #endif
    }
}

// MARK: - Preview

#Preview("With photos") {
    LocationCalloutView(location: .preview)
}

#Preview("No photos") {
    LocationCalloutView(location: .previewNoPhotos)
}

extension ScoutLocation {
    static let preview = ScoutLocation(
        name: "Vasquez Rocks Natural Area",
        description: "Agua Dulce, CA 93510 — iconic tilted sandstone formations used in countless films and TV shows",
        coordinate: .init(latitude: 34.4883, longitude: -118.3214),
        sourceURL: URL(string: "https://en.wikipedia.org/wiki/Vasquez_Rocks"),
        images: [
            ScoutImage(url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/3/30/Vasquez_Rocks_2013.jpg/1280px-Vasquez_Rocks_2013.jpg"), source: .googleMaps),
            ScoutImage(url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a3/Vasquez_Rocks_County_Park_2.jpg/1280px-Vasquez_Rocks_County_Park_2.jpg"), source: .googleMaps),
            ScoutImage(url: URL(string: "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5e/Vasquez_Rocks.jpg/1280px-Vasquez_Rocks.jpg"), source: .googleMaps),
        ],
        googleMapsURL: URL(string: "https://www.google.com/maps/search/?api=1&query=34.4883,-118.3214")
    )

    static let previewNoPhotos = ScoutLocation(
        name: "Bronson Canyon",
        description: "Griffin Park, Los Angeles, CA — cave entrance used in Batman (1966) and many westerns",
        coordinate: .init(latitude: 34.1241, longitude: -118.3206),
        googleMapsURL: URL(string: "https://www.google.com/maps/search/?api=1&query=34.1241,-118.3206")
    )
}
