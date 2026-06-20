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

    func show(images: [ScoutImage], startingAt index: Int, location: ScoutLocation? = nil) {
        self.images = images
        self.location = location
        self.selectedIndex = index
        self.isVisible = true
    }

    func dismiss() { isVisible = false }

    func next() {
        if selectedIndex < images.count - 1 { selectedIndex += 1 }
    }

    func previous() {
        if selectedIndex > 0 { selectedIndex -= 1 }
    }
}
