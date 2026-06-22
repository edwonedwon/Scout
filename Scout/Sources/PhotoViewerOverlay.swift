import SwiftUI
import ScoutKit

// MARK: - Photo loading

#if os(macOS)
typealias ScoutImageType = NSImage
#else
typealias ScoutImageType = UIImage
#endif

/// The single loader for every remote photo in the app (sidebar, carousel, grid, and
/// map pins). One in-memory cache, one request builder.
enum PhotoLoader {
    private static let cache: NSCache<NSURL, ScoutImageType> = {
        let c = NSCache<NSURL, ScoutImageType>()
        c.countLimit = 200
        return c
    }()

    /// Builds the request for a photo URL. For Google Places URLs it strips any baked-in
    /// `?key=` param and sends the key as the `X-Goog-Api-Key` header instead — sending both
    /// 400s on some key configs, and header auth is what the search request uses.
    static func request(for url: URL) -> URLRequest {
        let isGoogle = url.host?.contains("places.googleapis.com") == true
        var target = url
        if isGoogle, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = comps.queryItems?.filter { $0.name != "key" }
            target = comps.url ?? url
        }
        var request = URLRequest(url: target)
        if isGoogle, let key = KeychainService.load(forKey: KeychainService.googleMapsAPIKey) {
            request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        }
        return request
    }

    static func cached(_ url: URL) -> ScoutImageType? { cache.object(forKey: url as NSURL) }

    static func load(_ url: URL) async -> ScoutImageType? {
        if let c = cached(url) { return c }
        guard let (data, resp) = try? await URLSession.shared.data(for: request(for: url)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let img = ScoutImageType(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

/// Async image view backed by `PhotoLoader` (Google header auth + shared cache).
struct GooglePhotoImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var image: ScoutImageType? = nil
    @State private var loadTask: Task<Void, Never>? = nil

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            } else {
                placeholder()
            }
        }
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: url?.absoluteString ?? "") { _, _ in load() }
    }

    private func load() {
        loadTask?.cancel()
        guard let url else { image = nil; return }
        if let cached = PhotoLoader.cached(url) { image = cached; return }
        image = nil
        loadTask = Task {
            let loaded = await PhotoLoader.load(url)
            guard !Task.isCancelled, let loaded else { return }
            await MainActor.run { image = loaded }
        }
    }
}

// MARK: -

struct PhotoViewerOverlay: View {
    @ObservedObject private var viewer = PhotoViewerState.shared
    @FocusState private var focused: Bool

    /// Lists available to save into. A nil list means a general (unfiled) pin.
    var availableLists: [LocationListData] = []
    var onSave: ((ScoutLocation, LocationListData?) -> Void)? = nil
    @State private var justSavedTo: String? = nil

    var body: some View {
        ZStack {
            // Backdrop — tap anywhere outside the scroll row to dismiss
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture { viewer.dismiss() }

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    if !viewer.images.isEmpty {
                        Text("\(viewer.selectedIndex + 1) / \(viewer.images.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    Spacer()
                    Button(action: viewer.dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                // Photo strip — paging scroll
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(viewer.images.enumerated()), id: \.offset) { idx, img in
                                GooglePhotoImage(url: img.url) {
                                    ProgressView().tint(.white)
                                }
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                                // Prevent taps on the photo from dismissing the backdrop
                                .contentShape(Rectangle())
                                .onTapGesture {}
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: Binding(
                        get: { viewer.selectedIndex },
                        set: { if let v = $0 { viewer.selectedIndex = v } }
                    ))
                    .onChange(of: viewer.selectedIndex) { _, idx in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(viewer.selectedIndex, anchor: .center)
                        focused = true
                    }
                }

                // Bottom: dots + arrows + location info
                VStack(spacing: 10) {
                    // Dot indicators (up to 10)
                    if viewer.images.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(0..<min(viewer.images.count, 10), id: \.self) { idx in
                                Circle()
                                    .fill(idx == viewer.selectedIndex ? Color.white : Color.white.opacity(0.35))
                                    .frame(width: idx == viewer.selectedIndex ? 7 : 5, height: idx == viewer.selectedIndex ? 7 : 5)
                                    .animation(.spring(duration: 0.2), value: viewer.selectedIndex)
                                    .onTapGesture { viewer.selectedIndex = idx }
                            }
                        }
                    }

                    // Arrow buttons — keep always-active so they absorb taps
                    // even at the boundary (prevents accidental backdrop dismiss).
                    HStack(spacing: 32) {
                        Button {
                            viewer.previous()
                        } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 36))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .opacity(viewer.selectedIndex > 0 ? 1 : 0.2)
                                .frame(width: 60, height: 60)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            viewer.next()
                        } label: {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 36))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .opacity(viewer.selectedIndex < viewer.images.count - 1 ? 1 : 0.2)
                                .frame(width: 60, height: 60)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Per-photo date
                    let currentImage = viewer.images.indices.contains(viewer.selectedIndex)
                        ? viewer.images[viewer.selectedIndex] : nil
                    if let date = currentImage?.dateTaken {
                        Text(date.formatted(.dateTime.year().month(.wide).day()))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .monospacedDigit()
                            .transition(.opacity)
                            .id(viewer.selectedIndex)
                    }

                    // Location info bar
                    if let loc = viewer.location {
                        locationInfoBar(loc)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow)  { viewer.previous(); return .handled }
        .onKeyPress(.rightArrow) { viewer.next();     return .handled }
        // Escape is handled app-wide in ContentView.handleEscape (carousel → grid).
    }

    @ViewBuilder
    private func locationInfoBar(_ loc: ScoutLocation) -> some View {
        VStack(spacing: 6) {
            Text(loc.name)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if !loc.description.isEmpty {
                Text(loc.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if let onSave {
                    saveMenu(for: loc, onSave: onSave)
                }

                if viewer.onViewOnMap != nil {
                    Button {
                        viewer.restoreOnPhotoMode = true
                        viewer.dismiss()
                        viewer.onViewOnMap?(loc)
                    } label: {
                        Label("Show on Map", systemImage: "map")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }

                if let mapsURL = loc.googleMapsURL {
                    Link(destination: mapsURL) {
                        Label("Google Maps", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }

                if let sourceURL = loc.sourceURL {
                    Link(destination: sourceURL) {
                        Label("Source", systemImage: "link")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func saveMenu(for loc: ScoutLocation, onSave: @escaping (ScoutLocation, LocationListData?) -> Void) -> some View {
        Menu {
            Button {
                onSave(loc, nil)
                flashSaved("Pinned")
            } label: {
                Label("Pin to Map (no list)", systemImage: "mappin")
            }

            if !availableLists.isEmpty {
                Divider()
                Section("Add to List") {
                    ForEach(availableLists) { list in
                        Button {
                            onSave(loc, list)
                            flashSaved(list.name)
                        } label: {
                            Label(listLabel(list), systemImage: "mappin.circle")
                        }
                    }
                }
            }
        } label: {
            Label(justSavedTo.map { "Saved · \($0)" } ?? "Save",
                  systemImage: justSavedTo != nil ? "checkmark" : "bookmark")
                .font(.caption.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(.white)
        .controlSize(.small)
        .fixedSize()
    }

    private func listLabel(_ list: LocationListData) -> String {
        list.project.map { "\($0.name) › \(list.name)" } ?? list.name
    }

    private func flashSaved(_ name: String) {
        withAnimation { justSavedTo = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if justSavedTo == name { justSavedTo = nil } }
        }
    }
}
