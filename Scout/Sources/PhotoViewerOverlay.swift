import SwiftUI
import CoreLocation
import ScoutKit

// MARK: - Photo loading

#if os(macOS)
typealias ScoutImageType = NSImage
#else
typealias ScoutImageType = UIImage
#endif

/// The single loader for every remote photo in the app (sidebar, carousel, grid, and
/// map pins). One in-memory cache, one request builder, plus a persistent on-disk cache so
/// each remote photo (notably billable Google Place Photos) is fetched over the network at
/// most once — ever, across relaunches — instead of being re-billed on every view.
enum PhotoLoader {
    private static let cache: NSCache<NSURL, ScoutImageType> = {
        let c = NSCache<NSURL, ScoutImageType>()
        c.countLimit = 200
        return c
    }()

    /// On-disk byte cache for remote images. Keyed by a stable hash of the URL.
    private static let diskCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ScoutRemotePhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func diskURL(for url: URL) -> URL {
        // FNV-1a hash of the absolute URL → stable filename, no collisions in practice.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return diskCacheDir.appendingPathComponent(String(hash, radix: 16))
    }

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

    /// Raw bytes for a photo URL — local files read directly; remote URLs are served from
    /// the on-disk cache when present, otherwise fetched once and persisted. This is what
    /// stops repeated/relaunched views of the same Google Place Photo from re-billing.
    static func data(for url: URL) async -> Data? {
        if url.isFileURL { return try? Data(contentsOf: url) }

        let disk = diskURL(for: url)
        if let cached = try? Data(contentsOf: disk) { return cached }

        guard let (data, resp) = try? await URLSession.shared.data(for: request(for: url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? data.write(to: disk)
        return data
    }

    static func load(_ url: URL) async -> ScoutImageType? {
        if let c = cached(url) { return c }
        guard let data = await data(for: url), let img = ScoutImageType(data: data) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

// MARK: - Offline pin photos

/// Downloads a saved pin's photos to disk so they display offline and never refetch.
/// Photos are resolved from the location's own image URLs, else its Google place ID,
/// else a last-resort name+area search on Google. Filenames (not absolute paths) are
/// stored on the pin and resolved against `directory` at load time so they survive
/// container path changes.
enum PinPhotoStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ScoutPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func fileURL(_ filename: String) -> URL { directory.appendingPathComponent(filename) }

    /// Downloaded photo filenames plus the source links resolved alongside them, so old
    /// pins can backfill their Google Maps / Flickr / Wiki link too.
    struct Result {
        var files: [String] = []
        var googleMapsURL: URL?
        var sourceURL: URL?
    }

    static func download(for location: ScoutLocation, placeId: String?, pinUUID: UUID, limit: Int = 5) async -> Result {
        let resolved = await resolve(for: location, placeId: placeId, limit: limit)
        var result = Result(googleMapsURL: resolved.googleMapsURL, sourceURL: resolved.sourceURL)
        for (i, url) in resolved.photoURLs.enumerated() where !url.isFileURL {
            guard let data = await PhotoLoader.data(for: url) else { continue }
            let name = "\(pinUUID.uuidString)-\(i).img"
            if (try? data.write(to: fileURL(name))) != nil { result.files.append(name) }
        }
        return result
    }

    private struct Resolved {
        var photoURLs: [URL] = []
        var googleMapsURL: URL?
        var sourceURL: URL?
    }

    private static func resolve(for location: ScoutLocation, placeId: String?, limit: Int) async -> Resolved {
        // Prefer the location's own stored source and photos.
        let stored = location.images.compactMap(\.url).filter { !$0.isFileURL }
        if !stored.isEmpty {
            return Resolved(photoURLs: Array(stored.prefix(limit)),
                            googleMapsURL: location.googleMapsURL, sourceURL: location.sourceURL)
        }
        if let placeId, let photos = try? await GooglePlacesService.shared.fetchPhotos(for: placeId) {
            let urls = photos.compactMap(\.url)
            if !urls.isEmpty {
                return Resolved(photoURLs: Array(urls.prefix(limit)),
                                googleMapsURL: location.googleMapsURL, sourceURL: location.sourceURL)
            }
        }
        // Last resort for old pins with no stored source: re-find on Google by name nearby.
        let c = location.coordinate
        let region = GooglePlacesService.MapRegion(centerLat: c.latitude, centerLng: c.longitude,
                                                   latDelta: 0.05, lngDelta: 0.05)
        if let results = try? await GooglePlacesService.shared.search(query: location.name, region: region),
           let best = results.min(by: { distSq($0.coordinate, c) < distSq($1.coordinate, c) }) {
            return Resolved(photoURLs: Array(best.images.compactMap(\.url).prefix(limit)),
                            googleMapsURL: best.googleMapsURL, sourceURL: best.sourceURL)
        }
        return Resolved(googleMapsURL: location.googleMapsURL, sourceURL: location.sourceURL)
    }

    private static func distSq(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dLat = a.latitude - b.latitude, dLng = a.longitude - b.longitude
        return dLat * dLat + dLng * dLng
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
                        LazyHStack(spacing: 0) {
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
                                .onAppear { viewer.prefetchNext(after: idx) }
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: Binding(
                        get: { viewer.selectedIndex },
                        // Only write when the index actually changed. Without this guard,
                        // any re-layout (e.g. the re-render triggered by saving a pin) calls
                        // the setter with the SAME index, which publishes a @Published change
                        // mid-view-update — "Publishing changes from within view updates" —
                        // and crashes.
                        set: { newValue in
                            guard let v = newValue, v != viewer.selectedIndex else { return }
                            viewer.selectedIndex = v
                        }
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
                                .opacity(viewer.hasPrevious ? 1 : 0.2)
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
                                .opacity(viewer.hasNext ? 1 : 0.2)
                                .frame(width: 60, height: 60)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Per-photo date/time (from EXIF DateTimeOriginal)
                    let currentImage = viewer.images.indices.contains(viewer.selectedIndex)
                        ? viewer.images[viewer.selectedIndex] : nil
                    if let date = currentImage?.dateTaken {
                        Text(date.formatted(.dateTime.year().month(.wide).day().hour().minute()))
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
                // Defer the model insert out of the menu's view-update cycle so the
                // resulting @Query re-render can't publish changes mid-update.
                DispatchQueue.main.async { onSave(loc, nil) }
                flashSaved("Pinned")
            } label: {
                Label("Pin to Map (no list)", systemImage: "mappin")
            }

            if !availableLists.isEmpty {
                Divider()
                Section("Add to List") {
                    ForEach(availableLists) { list in
                        Button {
                            DispatchQueue.main.async { onSave(loc, list) }
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

#if DEBUG
#Preview("Photo image") {
    GooglePhotoImage(url: ScoutLocation.preview.images.first?.url) {
        Color.secondary.opacity(0.15)
    }
    .scaledToFill()
    .frame(width: 220, height: 160)
    .clipped()
}

#Preview("Photo viewer") {
    PhotoViewerState.shared.images = ScoutLocation.preview.images
    PhotoViewerState.shared.location = .preview
    PhotoViewerState.shared.selectedIndex = 0
    return PhotoViewerOverlay()
        .frame(width: 800, height: 600)
}
#endif
