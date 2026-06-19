#if os(macOS)
import SwiftUI
import AppKit

/// Transparent overlay that intercepts trackpad scroll events and converts
/// vertical delta to map zoom when the "scroll to zoom" setting is enabled.
struct ScrollZoomOverlay: NSViewRepresentable {
    let enabled: Bool
    /// Called with a span multiplier: <1 zooms in, >1 zooms out
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ScrollInterceptView {
        ScrollInterceptView(enabled: enabled, onZoom: onZoom)
    }

    func updateNSView(_ nsView: ScrollInterceptView, context: Context) {
        nsView.enabled = enabled
        nsView.onZoom = onZoom
    }
}

class ScrollInterceptView: NSView {
    var enabled: Bool
    var onZoom: (Double) -> Void

    init(enabled: Bool, onZoom: @escaping (Double) -> Void) {
        self.enabled = enabled
        self.onZoom = onZoom
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        guard enabled, event.scrollingDeltaY != 0 else {
            super.scrollWheel(with: event)
            return
        }
        // Trackpad two-finger swipe: positive deltaY = fingers moved up = zoom in
        let sensitivity = 0.008
        let multiplier = pow(2.0, -event.scrollingDeltaY * sensitivity)
        onZoom(multiplier)
    }
}
#endif
