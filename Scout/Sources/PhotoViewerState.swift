import Foundation
import ScoutKit

@MainActor
final class PhotoViewerState: ObservableObject {
    static let shared = PhotoViewerState()
    private init() {}

    @Published var images: [ScoutImage] = []
    @Published var location: ScoutLocation? = nil
    @Published var selectedIndex: Int = 0
    @Published var isVisible = false

    // Set by ContentView to handle "Show on map" taps from the overlay
    var onViewOnMap: ((ScoutLocation) -> Void)?

    // Full ordered list of all locations available for sequential navigation.
    // Populated by PhotoGridView when a photo is tapped so left/right can
    // cross location boundaries seamlessly.
    private var allLocations: [ScoutLocation] = []
    private var globalLocationIndex: Int = 0

    /// Open the carousel at `index` within `location.images`, with `all` as
    /// the navigable universe (typically pinnedLocations + searchLocations).
    func show(images: [ScoutImage], startingAt index: Int,
              location: ScoutLocation? = nil,
              allLocations: [ScoutLocation] = []) {
        self.images = images
        self.location = location
        self.selectedIndex = index
        self.isVisible = true

        self.allLocations = allLocations
        if let location, let idx = allLocations.firstIndex(where: { $0.id == location.id }) {
            self.globalLocationIndex = idx
        } else {
            self.globalLocationIndex = 0
        }

        // If this location only has 1 photo (from search) but has a placeId,
        // fetch the rest in the background so the carousel can show them.
        if let placeId = location?.googlePlaceId, images.count <= 1 {
            fetchRemainingPhotos(placeId: placeId, alreadyLoaded: images)
        }
    }

    private func fetchRemainingPhotos(placeId: String, alreadyLoaded: [ScoutImage]) {
        Task {
            guard let fetched = try? await GooglePlacesService.shared.fetchPhotos(for: placeId),
                  !fetched.isEmpty else { return }
            // Merge: keep already-loaded first, append any new URLs not already present.
            let existingURLs = Set(alreadyLoaded.compactMap { $0.url?.absoluteString })
            let newImages = fetched.filter { img in
                guard let u = img.url?.absoluteString else { return false }
                return !existingURLs.contains(u)
            }
            guard !newImages.isEmpty else { return }
            // Only update if we're still showing the same location.
            if self.location?.googlePlaceId == placeId {
                self.images = alreadyLoaded + newImages
            }
        }
    }

    func dismiss() { isVisible = false }

    var restoreOnPhotoMode = false
    var openedFromMap = false

    func next() {
        if selectedIndex < images.count - 1 {
            selectedIndex += 1
        } else {
            advanceLocation(by: +1)
        }
    }

    func previous() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        } else {
            advanceLocation(by: -1)
        }
    }

    var hasNext: Bool {
        selectedIndex < images.count - 1 || globalLocationIndex < allLocations.count - 1
    }

    var hasPrevious: Bool {
        selectedIndex > 0 || globalLocationIndex > 0
    }

    /// Warm the disk/memory cache for the photo immediately after `index` so it's
    /// ready before the user taps the next arrow. Called from `onAppear` on each
    /// photo cell (LazyHStack fires this only when the cell becomes visible).
    func prefetchNext(after index: Int) {
        let next = index + 1
        guard images.indices.contains(next), let url = images[next].url else { return }
        Task.detached(priority: .background) {
            _ = await PhotoLoader.data(for: url)
        }
    }

    private func advanceLocation(by delta: Int) {
        let next = globalLocationIndex + delta
        guard allLocations.indices.contains(next) else { return }
        let nextLoc = allLocations[next]
        globalLocationIndex = next
        location = nextLoc
        images = nextLoc.images
        // When going back, land on the last photo of the previous location.
        selectedIndex = delta < 0 ? max(0, images.count - 1) : 0
    }
}
