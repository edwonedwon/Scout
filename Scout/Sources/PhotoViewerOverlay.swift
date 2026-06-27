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
        // No hard count limit — let memory pressure drive eviction instead.
        // Thumbnails are ~20-50 KB each; 1000 cached = ~50 MB, well within macOS norms.
        c.totalCostLimit = 150 * 1024 * 1024   // 150 MB ceiling
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
        if url.isFileURL {
            // File reads are blocking — run them off the cooperative thread pool.
            return await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        }

        let disk = diskURL(for: url)
        if let cached = await Task.detached(priority: .utility, operation: { try? Data(contentsOf: disk) }).value {
            return cached
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: request(for: url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        try? data.write(to: disk)
        return data
    }

    static func load(_ url: URL) async -> ScoutImageType? {
        if let c = cached(url) { return c }
        guard let data = await data(for: url) else { return nil }
        // Decode off the cooperative thread pool so heavy JPEG/HEIC work
        // doesn't starve other async tasks on the main executor.
        let isFile = url.isFileURL
        let img = await Task.detached(priority: .utility) { () -> ScoutImageType? in
            if isFile {
                return decodeImage(from: data)
            } else {
                return ScoutImageType(data: data) ?? decodeImage(from: data)
            }
        }.value
        guard let img else { return nil }
        // Cost = real DECODED memory (≈ w·h·4), NOT the compressed byte count. Using
        // data.count undercounts a decoded bitmap by 10-30× (a 2048px carousel image is
        // ~16 MB in memory but <1 MB as JPEG), so the cache silently held 1-2 GB of
        // bitmaps under a "150 MB" ceiling and thrashed memory on low-RAM machines.
        cache.setObject(img, forKey: url as NSURL, cost: decodedCost(img))
        return img
    }

    /// Approximate in-memory size of a decoded image in bytes (4 bytes per pixel).
    private static func decodedCost(_ img: ScoutImageType) -> Int {
        #if os(macOS)
        if let rep = img.representations.first, rep.pixelsWide > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(img.size.width * img.size.height) * 4
        #else
        return Int(img.size.width * img.scale * img.size.height * img.scale) * 4
        #endif
    }

    // MARK: - Downsampled thumbnails (photo grid)

    /// Synchronous cache hit for a downsampled thumbnail at `maxPixel`. Keyed separately
    /// from the full-size entry so the grid and carousel don't evict each other.
    static func cachedThumbnail(_ url: URL, maxPixel: Int) -> ScoutImageType? {
        cache.object(forKey: thumbKey(url, maxPixel))
    }

    /// Loads an image downsampled so its longest side ≤ `maxPixel`. Uses CGImageSource's
    /// thumbnail path, which decodes far less than a full decode and yields a small bitmap —
    /// so the grid holds many more images in the same memory budget (fewer re-decodes on
    /// scroll) and each decode is cheaper.
    static func loadThumbnail(_ url: URL, maxPixel: Int) async -> ScoutImageType? {
        if let c = cachedThumbnail(url, maxPixel: maxPixel) { return c }
        guard let data = await data(for: url) else { return nil }
        let img = await Task.detached(priority: .utility) { downsample(data, maxPixel: maxPixel) }.value
        guard let img else { return nil }
        cache.setObject(img, forKey: thumbKey(url, maxPixel), cost: decodedCost(img))
        return img
    }

    private static func thumbKey(_ url: URL, _ maxPixel: Int) -> NSURL {
        (URL(string: url.absoluteString + "#th\(maxPixel)") ?? url) as NSURL
    }

    private static func downsample(_ data: Data, maxPixel: Int) -> ScoutImageType? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // EXIF orientation is deliberately NOT applied here (WithTransform:false) so this
            // path produces the SAME raw/landscape base bitmap as the full-decode `decodeImage`
            // path (which uses CGImageSourceCreateImageAtIndex and ignores orientation). All of
            // a pin's stored `rotationQuarterTurns` are user deltas calibrated to that single
            // base, so every tier — grid/sidebar/map thumbnails, the large carousel, and the
            // full-res originals — renders the same orientation no matter which decode path or
            // file (derivative -thumb/-full vs. an EXIF-bearing original .HIF) is loaded.
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        #if os(macOS)
        return ScoutImageType(cgImage: cg, size: .zero)
        #else
        return ScoutImageType(cgImage: cg)
        #endif
    }

    private static func decodeImage(from data: Data) -> ScoutImageType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        #if os(macOS)
        return ScoutImageType(cgImage: cgImage, size: .zero)
        #else
        return ScoutImageType(cgImage: cgImage)
        #endif
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
    /// Counter-clockwise 90° steps applied to the loaded bitmap before display.
    /// Rotating the bitmap (not the view) keeps the swapped aspect ratio correct
    /// for layout — masonry sizing and aspect-fit all behave automatically.
    var rotationQuarterTurns: Int = 0
    /// When set, the image is decoded downsampled so its longest side ≈ this many pixels
    /// (rounded up to a small bucket). The photo grid passes the cell's pixel width so big
    /// source files become tiny bitmaps — many more fit in cache, scrolling stops re-decoding.
    var targetPixelSize: CGFloat? = nil
    /// Optional friendly label shown on the "not downloaded yet" placeholder. Falls back to the
    /// file's name. Pass the pin's name so a collaborator sees which photo is still downloading.
    var displayName: String? = nil
    let placeholder: () -> Placeholder

    @State private var image: ScoutImageType? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    /// True when the file isn't on disk yet (e.g. a shared photo still downloading from iCloud).
    @State private var pendingDownload = false

    init(url: URL?, rotationQuarterTurns: Int = 0, targetPixelSize: CGFloat? = nil,
         displayName: String? = nil,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.rotationQuarterTurns = rotationQuarterTurns
        self.targetPixelSize = targetPixelSize
        self.displayName = displayName
        self.placeholder = placeholder
    }

    /// Rounds a target display size up to a small bucket to avoid caching many near-identical
    /// sizes. Returns 0 when the cell is large enough that downsampling the (already small)
    /// source thumbnail wouldn't save anything — then we use the normal full decode.
    private func sizeBucket(_ s: CGFloat) -> Int {
        let px = Int(s.rounded())
        for b in [96, 128, 160, 192, 224, 256] where px <= b { return b }
        return 0
    }

    var body: some View {
        Group {
            if let image {
                #if os(macOS)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            } else if pendingDownload {
                pendingPlaceholder
            } else {
                placeholder()
            }
        }
        .onAppear { load() }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: url?.absoluteString ?? "") { _, _ in load() }
        .onChange(of: rotationQuarterTurns) { _, _ in load() }
        .onChange(of: targetPixelSize.map(sizeBucket) ?? 0) { _, _ in load() }
        // Reload when a photo blob is materialized to disk (shared photo finished downloading).
        .onReceive(NotificationCenter.default.publisher(for: PhotoBlobSync.didMaterializeNotification)) { _ in
            if pendingDownload { load() }
        }
    }

    /// "Not downloaded yet" state: a download icon over the placeholder with the filename visible.
    private var pendingPlaceholder: some View {
        ZStack {
            placeholder()
            VStack(spacing: 4) {
                Image(systemName: "photo.badge.arrow.down")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                Text(displayName ?? url?.lastPathComponent ?? "Photo")
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(6)
        }
    }

    private func load() {
        loadTask?.cancel()
        guard let url else { image = nil; pendingDownload = false; return }
        // A local file that isn't on disk yet = a shared photo still downloading from iCloud.
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            image = nil
            pendingDownload = true
            return
        }
        pendingDownload = false
        // Downsampled path for the grid: tiny bitmaps, many more fit in cache.
        let bucket = targetPixelSize.map(sizeBucket) ?? 0
        if bucket > 0 {
            if let cached = PhotoLoader.cachedThumbnail(url, maxPixel: bucket) {
                image = cached.rotatedCCW(quarterTurns: rotationQuarterTurns)
                return
            }
            image = nil
            loadTask = Task {
                let loaded = await PhotoLoader.loadThumbnail(url, maxPixel: bucket)
                guard !Task.isCancelled, let loaded else { return }
                let rotated = loaded.rotatedCCW(quarterTurns: rotationQuarterTurns)
                await MainActor.run { image = rotated }
            }
            return
        }
        if let cached = PhotoLoader.cached(url) {
            image = cached.rotatedCCW(quarterTurns: rotationQuarterTurns)
            return
        }
        image = nil
        loadTask = Task {
            let loaded = await PhotoLoader.load(url)
            guard !Task.isCancelled, let loaded else { return }
            let rotated = loaded.rotatedCCW(quarterTurns: rotationQuarterTurns)
            await MainActor.run { image = rotated }
        }
    }
}

extension ScoutImageType {
    /// Returns a copy rotated counter-clockwise by `quarterTurns` × 90°.
    /// `0` returns self unchanged. The returned image has swapped dimensions for odd turns.
    func rotatedCCW(quarterTurns: Int) -> ScoutImageType {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return self }
        let radians = CGFloat(turns) * (.pi / 2)
        #if os(macOS)
        let oldSize = size
        let swapped = (turns % 2 == 1)
        let newSize = swapped ? NSSize(width: oldSize.height, height: oldSize.width) : oldSize
        let result = NSImage(size: newSize)
        result.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
        transform.rotate(byRadians: radians)
        transform.translateX(by: -oldSize.width / 2, yBy: -oldSize.height / 2)
        transform.concat()
        draw(at: .zero, from: NSRect(origin: .zero, size: oldSize), operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
        #else
        let swapped = (turns % 2 == 1)
        let newSize = swapped ? CGSize(width: size.height, height: size.width) : size
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            c.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
        #endif
    }
}

// MARK: -

struct PhotoViewerOverlay: View {
    @ObservedObject private var viewer = PhotoViewerState.shared
    @FocusState private var focused: Bool

    /// Lists available to save into. A nil list means a general (unfiled) pin.
    var availableLists: [LocationListData] = []
    var onSave: ((ScoutLocation, LocationListData?) -> Void)? = nil
    /// Persists a 90° CCW rotation for the photo at the given file URL (the displayed image).
    var onRotate: ((URL) -> Void)? = nil
    /// Deletes the pin for the given location. The carousel closes immediately after.
    var onDelete: ((ScoutLocation) -> Void)? = nil
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
                    if onDelete != nil, viewer.location != nil {
                        Button(action: deleteCurrent) {
                            Image(systemName: "trash.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .help("Delete photo (⌫)")
                    }
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
                                GooglePhotoImage(url: img.url, rotationQuarterTurns: img.rotationQuarterTurns) {
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
        .onKeyPress(KeyEquivalent("r")) { rotateCurrent(); return .handled }
        .onKeyPress(.delete)        { deleteCurrent(); return .handled }
        .onKeyPress(.deleteForward) { deleteCurrent(); return .handled }
        // Escape is handled app-wide in ContentView.handleEscape (carousel → grid).
    }

    /// Deletes the pin for the current photo and closes the carousel immediately.
    /// Dismiss first so nothing re-renders against the about-to-be-deleted model.
    private func deleteCurrent() {
        guard let loc = viewer.location else { return }
        viewer.dismiss()
        onDelete?(loc)
    }

    /// Rotates the currently shown photo 90° counter-clockwise: updates the live image so it
    /// re-renders immediately, then persists the rotation to the model via onRotate.
    private func rotateCurrent() {
        guard viewer.images.indices.contains(viewer.selectedIndex) else { return }
        var img = viewer.images[viewer.selectedIndex]
        img.rotationQuarterTurns = ((img.rotationQuarterTurns - 1) % 4 + 4) % 4
        viewer.images[viewer.selectedIndex] = img
        if let url = img.url { onRotate?(url) }
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
                            // Save into the list, then close the carousel — once a photo
                            // is filed there's nothing left to do in the full-screen view.
                            DispatchQueue.main.async {
                                onSave(loc, list)
                                viewer.dismiss()
                            }
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
        list.name
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
