#if os(macOS)
import SwiftUI
import AppKit

struct ScrollZoomModifier: ViewModifier {
    let enabled: Bool
    /// Called with zoom multiplier and cursor fraction offset from window center (x,y in -0.5...0.5)
    let onZoom: (Double, CGPoint) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollZoomMonitorView(enabled: enabled, onZoom: onZoom)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func scrollZoom(enabled: Bool, onZoom: @escaping (Double, CGPoint) -> Void) -> some View {
        modifier(ScrollZoomModifier(enabled: enabled, onZoom: onZoom))
    }
}

private struct ScrollZoomMonitorView: NSViewRepresentable {
    let enabled: Bool
    let onZoom: (Double, CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(enabled: enabled, view: nsView, onZoom: onZoom)
    }

    class Coordinator {
        private var monitor: Any?
        private var onZoom: ((Double, CGPoint) -> Void)?

        func update(enabled: Bool, view: NSView, onZoom: @escaping (Double, CGPoint) -> Void) {
            self.onZoom = onZoom
            if enabled, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, event.scrollingDeltaY != 0 else { return event }

                    let loc = event.locationInWindow
                    guard let window = event.window,
                          let cv = window.contentView else { return event }

                    let bounds = cv.bounds
                    let fx = (loc.x - bounds.width  / 2) / bounds.width
                    let fy = (loc.y - bounds.height / 2) / bounds.height

                    let sensitivity = 0.006
                    let multiplier = pow(2.0, -event.scrollingDeltaY * sensitivity)
                    self.onZoom?(multiplier, CGPoint(x: fx, y: fy))
                    return nil
                }
            } else if !enabled, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
#endif
