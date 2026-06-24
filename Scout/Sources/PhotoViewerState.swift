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
