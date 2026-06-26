import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The third center-panel mode (Map / Photos / Script). Renders the active script's fountain
/// text as a paginated US-Letter screenplay (Courier 12, standard margins/indents) so the page
/// layout & count match a printed PDF export. Select a range and press `m` (or right-click) to
/// assign it to a list; assigned ranges are tinted with the list's colour.
struct ScriptView: View {
    let script: ScriptData?
    /// Called with the selected character range (into rawText) when the user presses `m`.
    var onAssign: ((NSRange) -> Void)? = nil
    /// Called to create a new list and assign the range to it (right-click menu).
    var onAssignNewList: ((NSRange) -> Void)? = nil
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
                    onAssign: onAssign,
                    onAssignNewList: onAssignNewList
                )
                .overlay(alignment: .bottom) {
                    Text("Select text and press  M  to assign it to a list")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.black.opacity(0.6), in: Capsule())
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
    static let background = Color(nsColor: NSColor(calibratedWhite: 0.22, alpha: 1))
    #else
    static let background = Color(white: 0.22)
    #endif
}

#if os(macOS)
// MARK: - Standard US screenplay metrics (points @ 72dpi)

enum Screenplay {
    static let pageW: CGFloat = 8.5 * 72   // 612
    static let pageH: CGFloat = 11.0 * 72  // 792
    static let marginTop: CGFloat = 72     // 1"
    static let marginBottom: CGFloat = 72  // 1"
    static let marginLeft: CGFloat = 1.5 * 72   // 108
    static let marginRight: CGFloat = 72        // 1"
    static let textW = pageW - marginLeft - marginRight   // 432 (6")
    static let textH = pageH - marginTop - marginBottom   // 648 (9")
    /// 6 lines per inch — the typewriter standard that drives screenplay page count.
    static let lineHeight: CGFloat = 12
    static let pageGap: CGFloat = 18
    static let font: NSFont = NSFont(name: "Courier", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont: NSFont = NSFont(name: "Courier-Bold", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .bold)
}

/// A top-down (flipped) container view so pages stack from the top.
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Renders the script as discrete US-Letter pages via a shared NSLayoutManager with one text
/// container per page. Selection & highlight offsets map 1:1 to `rawText` (the rendered string
/// IS the raw text). Page breaks are line-based at standard metrics — close to an exported PDF.
struct ScriptTextRepresentable: NSViewRepresentable {
    let text: String
    let highlights: [(NSRange, NSColor)]
    var scrollTarget: NSRange?
    var onAssign: ((NSRange) -> Void)?
    var onAssignNewList: ((NSRange) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        context.coordinator.scroll = scroll
        context.coordinator.onAssign = onAssign
        context.coordinator.onAssignNewList = onAssignNewList
        context.coordinator.rebuild(text: text, highlights: highlights)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onAssign = onAssign
        context.coordinator.onAssignNewList = onAssignNewList
        if context.coordinator.needsRebuild(text: text, highlights: highlights) {
            context.coordinator.rebuild(text: text, highlights: highlights)
        }
        // Scroll to & select a requested range when it changes (reset to nil between requests
        // so re-clicking the same scene re-scrolls).
        if let target = scrollTarget {
            if context.coordinator.lastScrollTarget != target {
                context.coordinator.lastScrollTarget = target
                context.coordinator.scrollTo(range: target)
            }
        } else {
            context.coordinator.lastScrollTarget = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var scroll: NSScrollView?
        var onAssign: ((NSRange) -> Void)?
        var onAssignNewList: ((NSRange) -> Void)?
        var lastScrollTarget: NSRange?

        private var storage: NSTextStorage?
        private var layout: NSLayoutManager?
        private var pageTextViews: [ScriptNSTextView] = []
        private var lastText = "\u{0}"
        private var lastHL: [(NSRange, NSColor)] = []

        func needsRebuild(text: String, highlights: [(NSRange, NSColor)]) -> Bool {
            if text != lastText { return true }
            if highlights.count != lastHL.count { return true }
            for (a, b) in zip(highlights, lastHL) where a.0 != b.0 || a.1 != b.1 { return true }
            return false
        }

        func rebuild(text: String, highlights: [(NSRange, NSColor)]) {
            guard let scroll else { return }
            lastText = text; lastHL = highlights

            let storage = NSTextStorage(attributedString: ScreenplayRenderer.attributedString(text, highlights: highlights))
            let layout = NSLayoutManager()
            layout.usesFontLeading = false
            storage.addLayoutManager(layout)
            self.storage = storage
            self.layout = layout
            pageTextViews = []

            // Add one container per page until all characters are laid out.
            let total = storage.length
            var lastChar = 0
            var containers: [NSTextContainer] = []
            var guardCount = 0
            while lastChar < total && guardCount < 5000 {
                let c = NSTextContainer(size: NSSize(width: Screenplay.textW, height: Screenplay.textH))
                c.lineFragmentPadding = 0
                layout.addTextContainer(c)
                let gr = layout.glyphRange(for: c)            // forces layout for this container
                if gr.length == 0 { break }
                let cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                lastChar = cr.location + cr.length
                containers.append(c)
                guardCount += 1
            }
            if containers.isEmpty {
                let c = NSTextContainer(size: NSSize(width: Screenplay.textW, height: Screenplay.textH))
                c.lineFragmentPadding = 0
                layout.addTextContainer(c)
                containers.append(c)
            }

            // Build the stacked page sheets.
            let doc = FlippedView(frame: .zero)
            for (i, container) in containers.enumerated() {
                let y = Screenplay.pageGap + CGFloat(i) * (Screenplay.pageH + Screenplay.pageGap)
                let sheet = FlippedView(frame: NSRect(x: 0, y: y, width: Screenplay.pageW, height: Screenplay.pageH))
                sheet.wantsLayer = true
                sheet.layer?.backgroundColor = NSColor.white.cgColor
                sheet.shadow = { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.4); s.shadowBlurRadius = 8; s.shadowOffset = NSSize(width: 0, height: -2); return s }()

                let tv = ScriptNSTextView(
                    frame: NSRect(x: Screenplay.marginLeft, y: Screenplay.marginTop,
                                  width: Screenplay.textW, height: Screenplay.textH),
                    textContainer: container)
                tv.isEditable = false
                tv.isSelectable = true
                tv.drawsBackground = false
                tv.textContainerInset = .zero
                tv.isVerticallyResizable = false
                tv.isHorizontallyResizable = false
                tv.minSize = NSSize(width: Screenplay.textW, height: Screenplay.textH)
                tv.maxSize = NSSize(width: Screenplay.textW, height: Screenplay.textH)
                tv.coordinatorRef = self
                sheet.addSubview(tv)
                pageTextViews.append(tv)

                if i > 0 {   // first page is unnumbered, per convention
                    let num = NSTextField(labelWithString: "\(i + 1).")
                    num.font = Screenplay.font
                    num.textColor = .black
                    num.alignment = .right
                    num.frame = NSRect(x: Screenplay.pageW - Screenplay.marginRight - 60, y: 36, width: 60, height: 14)
                    sheet.addSubview(num)
                }
                doc.addSubview(sheet)
            }
            let docW = Screenplay.pageW
            let docH = Screenplay.pageGap + CGFloat(containers.count) * (Screenplay.pageH + Screenplay.pageGap)
            doc.frame = NSRect(x: 0, y: 0, width: docW, height: docH)
            scroll.documentView = doc
        }

        /// Called by a page's text view to forward an assign action (selectedRange is in the
        /// shared storage = rawText offsets).
        func assign(_ range: NSRange) { onAssign?(range) }
        func assignNewList(_ range: NSRange) { onAssignNewList?(range) }

        func scrollTo(range: NSRange) {
            guard let layout, let scroll, let storage, range.location < storage.length else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            guard let container = layout.textContainer(forGlyphAt: glyph, effectiveRange: nil),
                  let pageIndex = layout.textContainers.firstIndex(of: container),
                  pageIndex < pageTextViews.count else { return }
            let tv = pageTextViews[pageIndex]
            if range.location + range.length <= (tv.string as NSString).length {
                tv.setSelectedRange(range)
                tv.window?.makeFirstResponder(tv)
            }
            // Scroll the page (plus the in-page offset) into view.
            if let sheet = tv.superview {
                let rectInDoc = sheet.frame
                scroll.documentView?.scrollToVisible(rectInDoc)
            }
        }
    }
}

/// NSTextView for one screenplay page. A plain `m` keypress (with a selection) or the right-click
/// menu forwards an "assign" action to the shared coordinator.
final class ScriptNSTextView: NSTextView {
    weak var coordinatorRef: ScriptTextRepresentable.Coordinator?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, event.charactersIgnoringModifiers == "m" {
            let r = selectedRange()
            if r.length > 0 { coordinatorRef?.assign(r); return }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var range = selectedRange()
        // No selection? If the right-click lands inside an existing (tinted) highlight, use it.
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
        let assign = NSMenuItem(title: "Assign to list", action: #selector(assignFromMenu), keyEquivalent: "")
        assign.target = self
        menu.addItem(assign)
        let newList = NSMenuItem(title: "Create new list and assign", action: #selector(assignNewListFromMenu), keyEquivalent: "")
        newList.target = self
        menu.addItem(newList)
        return menu
    }

    @objc private func assignFromMenu() {
        let r = selectedRange()
        if r.length > 0 { coordinatorRef?.assign(r) }
    }
    @objc private func assignNewListFromMenu() {
        let r = selectedRange()
        if r.length > 0 { coordinatorRef?.assignNewList(r) }
    }
}

/// Builds a screenplay-styled `NSAttributedString` that preserves the EXACT raw text (so
/// selection ranges and stored highlight offsets map 1:1 to `rawText`). Black Courier 12 on white,
/// fixed 12pt line height (6 LPI), standard element indents. Blank lines in the source provide the
/// vertical spacing (and are counted), exactly as screenplay pagination expects.
enum ScreenplayRenderer {
    static func attributedString(_ raw: String, highlights: [(NSRange, NSColor)] = []) -> NSAttributedString {
        let out = NSMutableAttributedString(string: raw)
        let full = NSRange(location: 0, length: (raw as NSString).length)
        out.addAttributes([.font: Screenplay.font, .foregroundColor: NSColor.black,
                           .paragraphStyle: paragraph()], range: full)

        for el in FountainParser.parse(raw) {
            let r = NSIntersectionRange(el.range, full)
            guard r.length > 0 else { continue }
            let (font, para) = style(for: el.type)
            out.addAttributes([.font: font, .paragraphStyle: para], range: r)
        }
        for (range, color) in highlights {
            let r = NSIntersectionRange(range, full)
            guard r.length > 0 else { continue }
            out.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: r)
        }
        return out
    }

    private static func paragraph(head: CGFloat = 0, tail: CGFloat = 0,
                                  alignment: NSTextAlignment = .left) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = Screenplay.lineHeight
        p.maximumLineHeight = Screenplay.lineHeight
        p.firstLineHeadIndent = head
        p.headIndent = head
        p.tailIndent = tail
        p.alignment = alignment
        return p
    }

    private static func style(for type: FountainElementType) -> (NSFont, NSParagraphStyle) {
        let inch = CGFloat(72)
        switch type {
        case .sceneHeading:
            return (Screenplay.boldFont, paragraph())
        case .action:
            return (Screenplay.font, paragraph())
        case .character:
            return (Screenplay.font, paragraph(head: 2.2 * inch))            // 3.7" from page edge
        case .parenthetical:
            return (Screenplay.font, paragraph(head: 1.6 * inch, tail: -1.9 * inch))
        case .dialogue:
            return (Screenplay.font, paragraph(head: 1.0 * inch, tail: -1.5 * inch))  // ~3.5" wide
        case .transition:
            return (Screenplay.font, paragraph(alignment: .right))
        case .centered:
            return (Screenplay.font, paragraph(alignment: .center))
        case .titlePage:
            return (Screenplay.font, paragraph(alignment: .center))
        case .section:
            return (Screenplay.boldFont, paragraph())
        case .synopsis:
            return (Screenplay.font, paragraph())
        case .pageBreak, .blank:
            return (Screenplay.font, paragraph())
        }
    }
}
#endif
