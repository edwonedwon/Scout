import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Hex color helper

extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0xFF6B35
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Scrollbar gutter

#if os(macOS)
/// Forces the enclosing List's NSScrollView to use overlay scrollers (which never push
/// content) and reserves a constant right-hand content inset, so row width stays identical
/// whether or not the scrollbar is showing. Fixes the layout jump on long lists.
struct ScrollerGutterReserver: NSViewRepresentable {
    var width: CGFloat = 14

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in apply(from: v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(from: nsView) }
    }

    private func apply(from view: NSView?) {
        guard let view, let scroll = findScrollView(from: view) else { return }
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        // Keep the scroller permanently present. When the system uses legacy (in-line)
        // scrollers — "Always" in System Settings, or whenever a mouse is attached — an
        // autohiding scroller pops in on scroll and steals width from the rows, squeezing
        // them. Pinning it on means the content width never changes.
        scroll.autohidesScrollers = false
        scroll.automaticallyAdjustsContentInsets = false
        let cur = scroll.contentInsets
        guard cur.right != width else { return }
        scroll.contentInsets = NSEdgeInsets(top: cur.top, left: cur.left, bottom: cur.bottom, right: width)
    }

    /// Walks up from the background view, scanning each ancestor's subtree for the table's
    /// scroll view. The nearest match is the sidebar List's scroll view.
    private func findScrollView(from view: NSView) -> NSScrollView? {
        var current: NSView? = view
        while let v = current {
            if let sv = firstTableScrollView(in: v) { return sv }
            current = v.superview
        }
        return nil
    }

    private func firstTableScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, sv.documentView is NSTableView { return sv }
        for sub in view.subviews {
            if let found = firstTableScrollView(in: sub) { return found }
        }
        return nil
    }
}
#endif
