import Foundation
import ScoutKit

@MainActor
final class PhotoViewerState: ObservableObject {
    static let shared = PhotoViewerState()
    private init() {}

    @Published var images: [ScoutImage] = []
    @Published var selectedIndex: Int = 0
    @Published var isVisible = false

    func show(images: [ScoutImage], startingAt index: Int) {
        self.images = images
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
