import SwiftUI
import ScoutKit

struct LocationCalloutView: View {
    let location: ScoutLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photos
            if !location.images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        ForEach(location.images.prefix(8)) { img in
                            AsyncImage(url: img.url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                                    .overlay(ProgressView().controlSize(.small))
                            }
                            .frame(width: 160, height: 120)
                            .clipped()
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .background(.background)
    }

    static func height(for location: ScoutLocation) -> CGFloat {
        var h: CGFloat = 24  // vertical padding
        if !location.images.isEmpty { h += 120 }
        h += 28  // name
        if !location.description.isEmpty { h += 52 }
        let hasLinks = location.googleMapsURL != nil || location.sourceURL != nil
        if hasLinks { h += 28 }
        return h
    }
}
