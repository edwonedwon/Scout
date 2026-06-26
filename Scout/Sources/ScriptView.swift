import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The third center-panel mode (Map / Photos / Script). Renders the active script's fountain
/// text as readable, styled, scrollable text. Select a range and press `m` to assign it to a
/// list; assigned ranges are tinted with the list's colour.
struct ScriptView: View {
    let script: ScriptData?
    /// Called with the selected character range (into rawText) when the user presses `m`.
    var onAssign: ((NSRange) -> Void)? = nil
    /// When set, the view scrolls to & selects this range (used by "open scene from a list").
    var scrollTarget: NSRange? = nil

    var body: some View {
        Group {
            if let script {
                #if os(macOS)
                ScriptTextRepresentable(
                    text: script.rawText,
                    highlights: Self.highlightRanges(for: script),
                    scrollTarget: scrollTarget,
                    onAssign: onAssign
                )
                .overlay(alignment: .bottom) {
                    Text("Select text and press  M  to assign it to a list")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
                #else
                ScrollView { Text(script.rawText).font(.system(.body, design: .monospaced)).padding() }
                #endif
            } else {
                ContentUnavailableView(
                    "No Script",
                    systemImage: "doc.text",
                    description: Text("Import a .fountain script from the sidebar to read it here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ScriptStyle.background)
    }

    #if os(macOS)
    /// Maps a script's highlights → (range, colour) pairs for rendering.
    static func highlightRanges(for script: ScriptData) -> [(NSRange, NSColor)] {
        script.highlights.compactMap { h in
            guard let hex = h.list?.colorHex, let color = NSColor(hexString: hex) else { return nil }
            return (NSRange(location: h.rangeStart, length: h.rangeLength), color)
        }
    }
    #endif
}

private enum ScriptStyle {
    #if os(macOS)
    static let background = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1))
    #else
    static let background = Color.black
    #endif
}

#if os(macOS)
/// Read-only `NSTextView` (selection enabled) showing the fountain text styled per element, with
/// list-coloured highlight backgrounds. Pressing `m` with a selection calls `onAssign`.
struct ScriptTextRepresentable: NSViewRepresentable {
    let text: String
    let highlights: [(NSRange, NSColor)]
    var scrollTarget: NSRange?
    var onAssign: ((NSRange) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)

        let tv = ScriptNSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        tv.textContainerInset = NSSize(width: 28, height: 28)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.onAssign = onAssign

        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.render(text, highlights: highlights)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ScriptNSTextView else { return }
        tv.onAssign = onAssign
        if context.coordinator.needsRender(text: text, highlights: highlights) {
            context.coordinator.render(text, highlights: highlights)
        }
        // Scroll to (and select) a requested range when it changes. The caller resets the
        // target to nil between requests (so re-clicking the SAME scene re-scrolls); mirror
        // that here so the next non-nil value always triggers.
        if let target = scrollTarget {
            if context.coordinator.lastScrollTarget != target {
                context.coordinator.lastScrollTarget = target
                let ns = tv.string as NSString
                if target.location + target.length <= ns.length {
                    tv.setSelectedRange(target)
                    tv.scrollRangeToVisible(target)
                    tv.window?.makeFirstResponder(tv)
                }
            }
        } else {
            context.coordinator.lastScrollTarget = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var textView: ScriptNSTextView?
        private var lastText = "\u{0}"
        private var lastHL: [(NSRange, NSColor)] = []
        var lastScrollTarget: NSRange?

        func needsRender(text: String, highlights: [(NSRange, NSColor)]) -> Bool {
            if text != lastText { return true }
            if highlights.count != lastHL.count { return true }
            for (a, b) in zip(highlights, lastHL) where a.0 != b.0 || a.1 != b.1 { return true }
            return false
        }

        func render(_ text: String, highlights: [(NSRange, NSColor)]) {
            textView?.textStorage?.setAttributedString(FountainRenderer.attributedString(text, highlights: highlights))
            lastText = text
            lastHL = highlights
        }
    }
}

/// NSTextView that turns a plain `m` keypress (with a selection) into an "assign" callback,
/// and offers the same action via a right-click menu.
final class ScriptNSTextView: NSTextView {
    var onAssign: ((NSRange) -> Void)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, event.charactersIgnoringModifiers == "m" {
            let r = selectedRange()
            if r.length > 0 { onAssign?(r); return }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var range = selectedRange()
        // No active selection? If the right-click lands inside an existing (tinted) highlight,
        // target that whole highlight instead.
        if range.length == 0, let storage = textStorage {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            if idx >= 0, idx < storage.length,
               storage.attribute(.backgroundColor, at: idx, effectiveRange: nil) != nil {
                var eff = NSRange()
                _ = storage.attribute(.backgroundColor, at: idx, longestEffectiveRange: &eff,
                                      in: NSRange(location: 0, length: storage.length))
                range = eff
                setSelectedRange(eff)
            }
        }
        guard range.length > 0 else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Assign highlight to list",
                              action: #selector(assignFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func assignFromMenu() {
        let r = selectedRange()
        if r.length > 0 { onAssign?(r) }
    }
}

/// Builds a styled `NSAttributedString` that preserves the EXACT raw text (so selection ranges
/// and stored highlight offsets map 1:1 to `rawText`); styling is applied per parsed element,
/// and highlight backgrounds are tinted with each linked list's colour.
enum FountainRenderer {
    private static let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private static let textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
    private static let dimColor  = NSColor(calibratedWhite: 0.60, alpha: 1)

    static func attributedString(_ raw: String, highlights: [(NSRange, NSColor)] = []) -> NSAttributedString {
        let out = NSMutableAttributedString(string: raw)
        let full = NSRange(location: 0, length: (raw as NSString).length)
        out.addAttributes([.font: base, .foregroundColor: textColor], range: full)

        for el in FountainParser.parse(raw) {
            let r = NSIntersectionRange(el.range, full)
            guard r.length > 0 else { continue }
            let (font, color, para) = style(for: el.type)
            out.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: para], range: r)
        }
        for (range, color) in highlights {
            let r = NSIntersectionRange(range, full)
            guard r.length > 0 else { continue }
            out.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.40), range: r)
        }
        return out
    }

    private static func style(for type: FountainElementType) -> (NSFont, NSColor, NSParagraphStyle) {
        let p = NSMutableParagraphStyle(); p.lineSpacing = 2
        switch type {
        case .sceneHeading:
            p.paragraphSpacingBefore = 16; p.paragraphSpacing = 4
            return (bold, textColor, p)
        case .action:
            p.paragraphSpacingBefore = 8
            return (base, textColor, p)
        case .character:
            p.firstLineHeadIndent = 150; p.headIndent = 150; p.paragraphSpacingBefore = 8
            return (base, textColor, p)
        case .parenthetical:
            p.firstLineHeadIndent = 120; p.headIndent = 120
            return (base, dimColor, p)
        case .dialogue:
            p.firstLineHeadIndent = 70; p.headIndent = 70; p.tailIndent = -70
            return (base, textColor, p)
        case .transition:
            p.alignment = .right; p.paragraphSpacingBefore = 8
            return (bold, dimColor, p)
        case .section:
            p.paragraphSpacingBefore = 18; p.paragraphSpacing = 4
            return (NSFont.monospacedSystemFont(ofSize: 15, weight: .bold), NSColor.controlAccentColor, p)
        case .synopsis:
            p.paragraphSpacingBefore = 4
            return (base, dimColor, p)
        case .centered:
            p.alignment = .center; p.paragraphSpacingBefore = 6
            return (base, textColor, p)
        case .titlePage:
            p.alignment = .center
            return (base, textColor, p)
        case .pageBreak:
            p.alignment = .center; p.paragraphSpacingBefore = 12; p.paragraphSpacing = 12
            return (base, dimColor, p)
        case .blank:
            return (base, textColor, p)
        }
    }
}

#endif
