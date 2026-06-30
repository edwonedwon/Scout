import SwiftUI
import MapKit
import ScoutKit

enum MapStyle: String, CaseIterable, Identifiable {
    case explore, satellite, hybrid, muted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .explore:   "Explore"
        case .satellite: "Satellite"
        case .hybrid:    "Hybrid"
        case .muted:     "Muted"
        }
    }

    var icon: String {
        switch self {
        case .explore:   "map"
        case .satellite: "globe.americas"
        case .hybrid:    "globe.americas.fill"
        case .muted:     "square.dashed"
        }
    }

    // Thumbnail card background
    var cardBackground: Color {
        switch self {
        case .explore:   Color(.sRGB, red: 0.87, green: 0.93, blue: 0.82)
        case .satellite: Color(.sRGB, red: 0.12, green: 0.22, blue: 0.16)
        case .hybrid:    Color(.sRGB, red: 0.18, green: 0.28, blue: 0.22)
        case .muted:     Color(.sRGB, red: 0.88, green: 0.87, blue: 0.85)
        }
    }

    var iconColor: Color {
        switch self {
        case .explore:   .green
        case .satellite: .white
        case .hybrid:    .white
        case .muted:     .secondary
        }
    }

    var mapType: MKMapType {
        switch self {
        case .explore:   .standard
        case .satellite: .satellite
        case .hybrid:    .hybrid
        case .muted:     .mutedStandard
        }
    }
}

// MARK: - Layers popover

struct LayersPopover: View {
    @Binding var mapStyle: MapStyle
    @Binding var cyclingProviderRaw: String
    @Binding var pinSize: Double

    private var cyclingProvider: CyclingTileProvider? {
        CyclingTileProvider(rawValue: cyclingProviderRaw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Map type ──────────────────────────────────
            Text("Map Type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            HStack(spacing: 8) {
                ForEach(MapStyle.allCases) { style in
                    styleCard(style)
                }
            }
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 12)

            // ── Pins ──────────────────────────────────────
            Text("Pins")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                Label("Size", systemImage: "circle.dotted")
                    .font(.subheadline)
                Slider(value: $pinSize, in: 0.5...2.5)
                    .controlSize(.small)
                Text("\(Int(pinSize * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            Divider().padding(.bottom, 12)

            // ── Overlays ──────────────────────────────────
            Text("Overlays")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                // Cycling toggle header
                HStack {
                    Label("Cycling", systemImage: "bicycle")
                        .font(.subheadline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { cyclingProvider != nil },
                        set: { on in
                            cyclingProviderRaw = on ? CyclingTileProvider.cyclOSM.rawValue : ""
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                // Sub-options when cycling is on
                if cyclingProvider != nil {
                    Divider().padding(.leading, 12)
                    ForEach(CyclingTileProvider.allCases) { provider in
                        Button {
                            cyclingProviderRaw = provider.rawValue
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(provider.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(provider.description)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if cyclingProvider == provider {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        if provider != CyclingTileProvider.allCases.last {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .frame(width: 268)
    }

    private func styleCard(_ style: MapStyle) -> some View {
        let isSelected = mapStyle == style
        return Button { mapStyle = style } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(style.cardBackground)
                    Image(systemName: style.icon)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(style.iconColor)
                }
                .frame(height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                )
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

                Text(style.label)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

// MARK: - Boundary settings popover

struct BoundarySettingsPopover: View {
    @Binding var showPrefectures: Bool
    @Binding var showMunicipalities: Bool
    @Binding var showNames: Bool
    @Binding var opacity: Double
    @Binding var nameLanguage: BoundaryNameLanguage

    let isLoadingPrefectures: Bool
    let isLoadingMunicipalities: Bool
    let prefectureCount: Int
    let municipalityCount: Int
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Japan Boundaries")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Boundary Level").font(.caption).foregroundStyle(.secondary).padding(.bottom, 2)

                HStack {
                    Toggle(isOn: $showPrefectures) {
                        HStack(spacing: 4) {
                            Text("Prefectures")
                            if isLoadingPrefectures { ProgressView().controlSize(.mini) }
                            else if prefectureCount > 0 { Text("(\(prefectureCount))").foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    Spacer()
                }
                HStack {
                    Toggle(isOn: $showMunicipalities) {
                        HStack(spacing: 4) {
                            Text("Cities / Towns")
                            if isLoadingMunicipalities { ProgressView().controlSize(.mini) }
                            else if municipalityCount > 0 { Text("(\(municipalityCount))").foregroundStyle(.secondary).font(.caption) }
                        }
                    }
                    Spacer()
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Display").font(.caption).foregroundStyle(.secondary)

                Toggle("Show Names", isOn: $showNames)

                if showNames {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name language").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(BoundaryNameLanguage.allCases, id: \.self) { lang in
                                Toggle(isOn: Binding(
                                    get: { nameLanguage == lang },
                                    set: { if $0 { nameLanguage = lang } }
                                )) {
                                    Text(lang.label).font(.caption)
                                }
                                .toggleStyle(.button)
                                .controlSize(.small)
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }

                HStack {
                    Text("Fill Opacity").font(.subheadline)
                    Spacer()
                    Text("\(Int(opacity * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $opacity, in: 0.02...0.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .animation(.easeInOut(duration: 0.15), value: showNames)
        }
        .frame(width: 260)
    }
}

#if DEBUG
#Preview("Main layout", traits: .fixedLayout(width: 1200, height: 800)) {
    ContentView()
        .environmentObject(APIKeyState.shared)
        .onAppear {
            #if os(macOS)
            NSApp.windows.forEach { window in
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
            }
            #endif
        }
}

#Preview("Location row") {
    List {
        LocationRow(location: .preview)
        LocationRow(location: .previewNoPhotos)
        LocationRow(location: .preview, showsPhotos: false)
    }
    .frame(width: 320, height: 360)
}

#Preview("Layers popover") {
    @Previewable @State var style = MapStyle.explore
    @Previewable @State var cycling = ""
    @Previewable @State var size = 1.0
    LayersPopover(mapStyle: $style, cyclingProviderRaw: $cycling, pinSize: $size)
}

#Preview("Boundary popover") {
    @Previewable @State var prefectures = true
    @Previewable @State var municipalities = false
    @Previewable @State var names = true
    @Previewable @State var opacity = 0.2
    @Previewable @State var language = BoundaryNameLanguage.japanese
    BoundarySettingsPopover(
        showPrefectures: $prefectures,
        showMunicipalities: $municipalities,
        showNames: $names,
        opacity: $opacity,
        nameLanguage: $language,
        isLoadingPrefectures: false,
        isLoadingMunicipalities: false,
        prefectureCount: 47,
        municipalityCount: 0,
        error: nil
    )
}
#endif
