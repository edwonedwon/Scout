import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore   // CAMediaTimingFunction for the animated scroll-to-scene
/// Platform colour used for highlight tints. NSColor on macOS (consumed by the NSTextView
/// renderer); UIColor on iOS — where the script is shown as plain text and highlights are
/// ignored, but the type must still exist so the cross-platform `ScriptView` API compiles.
typealias ScriptHighlightColor = NSColor
#else
import UIKit
typealias ScriptHighlightColor = UIColor
#endif

/// The third center-panel mode (Map / Photos / Script). Renders the active script's fountain
/// text as a paginated US-Letter screenplay (Courier 12, standard margins/indents) so the page
/// layout & count match a printed PDF export. Select a range and press `m` (or right-click) to
/// assign it to a list; assigned ranges are tinted with the list's colour.
struct ScriptView: View {
    let script: ScriptVM?
    /// List-coloured highlight ranges to tint (supplied reactively by the owner).
    var highlights: [(NSRange, ScriptHighlightColor)] = []
    /// Called with the selected character range (into rawText) when the user presses `m`.
    var onAssign: ((NSRange) -> Void)? = nil
    /// Called to create a new list and assign the range to it (right-click menu).
    var onAssignNewList: ((NSRange) -> Void)? = nil
    /// Called to remove the highlight(s) overlapping the given range (right-click menu).
    var onRemoveHighlight: ((NSRange) -> Void)? = nil
    /// Called with a character offset when the user clicks a highlight — to select its linked list.
    var onHighlightClick: ((Int) -> Void)? = nil
    /// Page zoom (magnification) — Cmd +/- in Script mode; persisted by the owner.
    var zoom: CGFloat = 1.0
    /// When set, the view scrolls to & selects this range (used by "open scene from a list").
    var scrollTarget: NSRange? = nil

    var body: some View {
        Group {
            if let script {
                #if os(macOS)
                ScriptTextRepresentable(
                    text: script.rawText,
                    highlights: highlights,
                    scrollTarget: scrollTarget,
                    zoom: zoom,
                    onAssign: onAssign,
                    onAssignNewList: onAssignNewList,
                    onRemoveHighlight: onRemoveHighlight,
                    onHighlightClick: onHighlightClick
                )
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
}

private enum ScriptStyle {
    #if os(macOS)
    // The standard "behind document pages" colour — light grey in Light mode, dark in Dark mode.
    static let background = Color(nsColor: .underPageBackgroundColor)
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
    /// Line height. Screenplay standard is 12pt (6 LPI), which would be exactly 54 lines in the
    /// 648pt text area — but at exactly 54×12=648 there's zero slack, so NSLayoutManager's
    /// line-fragment rounding drops the 54th line on many pages and the script runs one page long.
    /// 11.9 keeps 54 lines fitting solidly (54×11.9=642.6 < 648) while 55 still never fit
    /// (55×11.9=654.5 > 648), so the page count matches an Arc Studio PDF export exactly.
    static let lineHeight: CGFloat = 11.9
    /// Horizontal slack added to the text container. The element widths work out to exact whole
    /// character counts (action 432pt = 60 chars, dialogue 252pt = 35 chars at 7.2pt/char), and at
    /// an exact boundary NSLayoutManager wraps one character early (59/34) — so every dialogue
    /// paragraph gains a line and, with this dialogue-heavy script, the whole thing runs a page
    /// long. ~half a character of slack lets the intended 60/35 chars fit without admitting 61/36.
    static let hSlack: CGFloat = 4
    /// Text container width (the page text area plus the wrap slack above).
    static var containerW: CGFloat { textW + hSlack }
    static let pageGap: CGFloat = 18
    static let font: NSFont = NSFont(name: "Courier", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont: NSFont = NSFont(name: "Courier-Bold", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .bold)
}

/// A top-down (flipped) document view that tracks the scroll view's width and keeps the page
/// sheets centred horizontally (so the script sits centred under the island).
final class ScriptDocView: NSView {
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        let clipW = enclosingScrollView?.contentView.bounds.width ?? bounds.width
        let w = max(Screenplay.pageW, clipW)
        if abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: frame.height)) }
        let x = ((w - Screenplay.pageW) / 2).rounded()
        for sub in subviews where sub.frame.origin.x != x {
            sub.frame.origin.x = x
        }
    }
}

/// One white (Light) / dark (Dark mode) page sheet. Draws its background so it follows the macOS
/// appearance live (a CGColor on a layer would not).
final class PageSheetView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Renders the script as discrete US-Letter pages via a shared NSLayoutManager with one text
/// container per page. Selection & highlight offsets map 1:1 to `rawText` (the rendered string
/// IS the raw text). Page breaks are line-based at standard metrics — close to an exported PDF.
struct ScriptTextRepresentable: NSViewRepresentable {
    let text: String
    let highlights: [(NSRange, NSColor)]
    var scrollTarget: NSRange?
    var zoom: CGFloat = 1.0
    var onAssign: ((NSRange) -> Void)?
    var onAssignNewList: ((NSRange) -> Void)?
    var onRemoveHighlight: ((NSRange) -> Void)?
    var onHighlightClick: ((Int) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        // Whole-page zoom (Cmd +/-, also pinch). Scales the pages, not the font.
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 3.0
        scroll.magnification = zoom
        context.coordinator.scroll = scroll
        context.coordinator.onAssign = onAssign
        context.coordinator.onAssignNewList = onAssignNewList
        context.coordinator.onRemoveHighlight = onRemoveHighlight
        context.coordinator.onHighlightClick = onHighlightClick
        context.coordinator.rebuild(text: text, highlights: highlights)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.onAssign = onAssign
        context.coordinator.onAssignNewList = onAssignNewList
        context.coordinator.onRemoveHighlight = onRemoveHighlight
        context.coordinator.onHighlightClick = onHighlightClick
        if abs(scroll.magnification - zoom) > 0.001 { scroll.magnification = zoom }
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
        var onRemoveHighlight: ((NSRange) -> Void)?
        var onHighlightClick: ((Int) -> Void)?
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
            // When only the highlights changed (e.g. assigning a scene to a list), the layout is
            // identical — preserve the scroll position so the page doesn't jump. Capture BEFORE
            // updating lastText (which still holds the previous text here).
            let textUnchanged = (text == lastText)
            let savedOrigin = scroll.contentView.bounds.origin
            lastText = text; lastHL = highlights

            let storage = NSTextStorage(attributedString: ScreenplayRenderer.attributedString(text, highlights: highlights))
            let layout = NSLayoutManager()
            layout.usesFontLeading = false
            storage.addLayoutManager(layout)
            self.storage = storage
            self.layout = layout
            pageTextViews = []

            // Character offsets of every scene heading — used to keep a heading off the bottom of
            // a page (screenplay "don't orphan a scene heading" rule).
            let sceneHeadingStarts = FountainParser.parse(text)
                .filter { $0.type == .sceneHeading }
                .map { $0.range.location }

            // Add one container per page until all characters are laid out.
            let total = storage.length
            var lastChar = 0
            var containers: [NSTextContainer] = []
            var guardCount = 0
            while lastChar < total && guardCount < 5000 {
                let c = NSTextContainer(size: NSSize(width: Screenplay.containerW, height: Screenplay.textH))
                c.lineFragmentPadding = 0
                layout.addTextContainer(c)
                var gr = layout.glyphRange(for: c)            // forces layout for this container
                if gr.length == 0 { break }
                var cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                let pageEnd = cr.location + cr.length
                // Orphan control: if a scene heading sits within the last ~3 lines of this page and
                // there's more content after it, shrink the page to push the heading to the next.
                if pageEnd < total,
                   let headingStart = sceneHeadingStarts.last(where: { $0 >= cr.location && $0 < pageEnd }) {
                    let g = layout.glyphIndexForCharacter(at: headingStart)
                    let frag = layout.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
                    if frag.minY > Screenplay.lineHeight,                       // not the top of the page
                       Screenplay.textH - frag.minY < Screenplay.lineHeight * 3 {  // < heading + 2 lines
                        c.size = NSSize(width: Screenplay.containerW, height: frag.minY)
                        gr = layout.glyphRange(for: c)
                        cr = layout.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
                    }
                }
                if gr.length == 0 { break }
                lastChar = cr.location + cr.length
                containers.append(c)
                guardCount += 1
            }
            if containers.isEmpty {
                let c = NSTextContainer(size: NSSize(width: Screenplay.containerW, height: Screenplay.textH))
                c.lineFragmentPadding = 0
                layout.addTextContainer(c)
                containers.append(c)
            }

            // Build the stacked page sheets in a self-centering document view.
            let doc = ScriptDocView(frame: .zero)
            doc.autoresizingMask = [.width]
            for (i, container) in containers.enumerated() {
                let y = Screenplay.pageGap + CGFloat(i) * (Screenplay.pageH + Screenplay.pageGap)
                let sheet = PageSheetView(frame: NSRect(x: 0, y: y, width: Screenplay.pageW, height: Screenplay.pageH))
                sheet.shadow = { let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.4); s.shadowBlurRadius = 8; s.shadowOffset = NSSize(width: 0, height: -2); return s }()

                let tv = ScriptNSTextView(
                    frame: NSRect(x: Screenplay.marginLeft, y: Screenplay.marginTop,
                                  width: Screenplay.containerW, height: Screenplay.textH),
                    textContainer: container)
                tv.isEditable = false
                tv.isSelectable = true
                tv.drawsBackground = false
                tv.textContainerInset = .zero
                tv.isVerticallyResizable = false
                tv.isHorizontallyResizable = false
                tv.minSize = NSSize(width: Screenplay.containerW, height: Screenplay.textH)
                tv.maxSize = NSSize(width: Screenplay.containerW, height: Screenplay.textH)
                tv.coordinatorRef = self
                sheet.addSubview(tv)
                pageTextViews.append(tv)

                if i > 0 {   // first page is unnumbered, per convention
                    let num = NSTextField(labelWithString: "\(i + 1).")
                    num.font = Screenplay.font
                    num.textColor = .secondaryLabelColor
                    num.alignment = .right
                    num.frame = NSRect(x: Screenplay.pageW - Screenplay.marginRight - 60, y: 36, width: 60, height: 14)
                    sheet.addSubview(num)
                }
                doc.addSubview(sheet)
            }
            let initialW = max(Screenplay.pageW, scroll.contentView.bounds.width)
            let docH = Screenplay.pageGap + CGFloat(containers.count) * (Screenplay.pageH + Screenplay.pageGap)
            doc.frame = NSRect(x: 0, y: 0, width: initialW, height: docH)
            scroll.documentView = doc
            doc.needsLayout = true

            // Restore the prior scroll position for a highlight-only rebuild so assigning a list
            // (or creating + assigning one) doesn't scroll/move the script at all.
            if textUnchanged {
                doc.layoutSubtreeIfNeeded()
                scroll.contentView.setBoundsOrigin(savedOrigin)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        /// Called by a page's text view to forward an assign action (selectedRange is in the
        /// shared storage = rawText offsets).
        func assign(_ range: NSRange) { onAssign?(range) }
        func assignNewList(_ range: NSRange) { onAssignNewList?(range) }
        func removeHighlight(_ range: NSRange) { onRemoveHighlight?(range) }
        func highlightClicked(_ offset: Int) { onHighlightClick?(offset) }

        /// Scrolls so the START of `range` sits near the top of the view (with breathing room
        /// above), without selecting it. Forces the position even if the range is already partly
        /// visible, so re-clicking the same scene always re-positions it. The scroll is animated
        /// (~1s, ease in/out) so the motion is visible but still snappy.
        func scrollTo(range: NSRange) {
            guard let layout, let scroll, let storage, range.location < storage.length else { return }
            let glyph = layout.glyphIndexForCharacter(at: range.location)
            guard let container = layout.textContainer(forGlyphAt: glyph, effectiveRange: nil),
                  let pageIndex = layout.textContainers.firstIndex(of: container),
                  pageIndex < pageTextViews.count else { return }
            let tv = pageTextViews[pageIndex]
            guard let sheet = tv.superview else { return }
            // Line's y in document coords: page text view → sheet → doc.
            let frag = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let docY = frag.minY + tv.frame.minY + sheet.frame.minY
            // Leave a comfortable gap above the landing line so it isn't jammed under the toolbar.
            let topInset: CGFloat = 80
            let clip = scroll.contentView
            let target = NSPoint(x: clip.bounds.origin.x, y: max(0, docY - topInset))
            // Animate the jump: ~1s, ease in/out, via the clip view's bounds-origin animator.
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 1.0
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(target)
            }, completionHandler: { [weak scroll, weak clip] in
                guard let scroll, let clip else { return }
                scroll.reflectScrolledClipView(clip)
            })
        }
    }
}

/// NSTextView for one screenplay page. A plain `m` keypress (with a selection) or the right-click
/// menu forwards an "assign" action to the shared coordinator.
final class ScriptNSTextView: NSTextView {
    weak var coordinatorRef: ScriptTextRepresentable.Coordinator?

    // A plain click on a tinted highlight selects its linked list (and reveals it in the sidebar)
    // instead of starting a text selection. Modifier-clicks and drags fall through to normal
    // selection so text can still be selected for assigning.
    override func mouseDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.isEmpty, event.clickCount == 1, let storage = textStorage {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            if idx >= 0, idx < storage.length,
               storage.attribute(.backgroundColor, at: idx, effectiveRange: nil) != nil {
                coordinatorRef?.highlightClicked(idx)
                return
            }
        }
        super.mouseDown(with: event)
    }

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
        var onHighlight = rangeHasHighlight(range)
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
                onHighlight = true
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
        if onHighlight {
            menu.addItem(.separator())
            let remove = NSMenuItem(title: "Remove Highlight", action: #selector(removeHighlightFromMenu), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }
        return menu
    }

    /// True if any character in `range` carries a list-colour highlight background.
    private func rangeHasHighlight(_ range: NSRange) -> Bool {
        guard range.length > 0, let storage = textStorage else { return false }
        var found = false
        storage.enumerateAttribute(.backgroundColor, in: range) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    @objc private func assignFromMenu() {
        let r = selectedRange()
        if r.length > 0 { coordinatorRef?.assign(r) }
    }
    @objc private func assignNewListFromMenu() {
        let r = selectedRange()
        if r.length > 0 { coordinatorRef?.assignNewList(r) }
    }
    @objc private func removeHighlightFromMenu() {
        let r = selectedRange()
        if r.length > 0 { coordinatorRef?.removeHighlight(r) }
    }
}

/// Builds a screenplay-styled `NSAttributedString`. The string is STILL the exact `rawText`
/// (every character kept, in order) so selection ranges and stored highlight offsets map 1:1 to
/// `rawText` — but fountain control markers (`!` `.` `@` `>` `<`) and emphasis delimiters
/// (`**` `*` `_`) are rendered INVISIBLE (clear, ~0pt) rather than removed, so the page reads like
/// a printed screenplay while offsets stay intact. Dynamic colours follow Light/Dark mode; fixed
/// 12pt line height (6 LPI); standard element indents. Blank lines in the source provide vertical
/// spacing (and are counted), exactly as screenplay pagination expects.
enum ScreenplayRenderer {
    /// Keeps a character in the text (so offsets don't shift) but makes it invisible & ~zero-width.
    private static let hiddenAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 0.01, weight: .regular),
        .foregroundColor: NSColor.clear
    ]

    static func attributedString(_ raw: String, highlights: [(NSRange, NSColor)] = []) -> NSAttributedString {
        let ns = raw as NSString
        let out = NSMutableAttributedString(string: raw)
        let full = NSRange(location: 0, length: ns.length)
        out.addAttributes([.font: Screenplay.font, .foregroundColor: NSColor.textColor,
                           .paragraphStyle: paragraph()], range: full)

        for el in FountainParser.parse(raw) {
            let r = NSIntersectionRange(el.range, full)
            guard r.length > 0 else { continue }
            let (font, para) = style(for: el.type)
            out.addAttributes([.font: font, .paragraphStyle: para], range: r)
            for m in markerRanges(for: el, in: ns) { out.addAttributes(hiddenAttrs, range: m) }
        }

        applyEmphasis(out, raw: raw, full: full)

        for (range, color) in highlights {
            let r = NSIntersectionRange(range, full)
            guard r.length > 0 else { continue }
            out.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.35), range: r)
        }
        return out
    }

    /// The control-marker character range(s) to hide for an element, located in the raw text
    /// (skipping leading whitespace) so they map back to real offsets.
    private static func markerRanges(for el: FountainElement, in ns: NSString) -> [NSRange] {
        let end = el.range.location + el.range.length
        var start = el.range.location
        while start < end {
            let c = ns.substring(with: NSRange(location: start, length: 1))
            if c == " " || c == "\t" { start += 1 } else { break }
        }
        guard start < end else { return [] }
        func char(_ off: Int) -> String? {
            let i = start + off
            return i < end ? ns.substring(with: NSRange(location: i, length: 1)) : nil
        }
        var ranges: [NSRange] = []
        switch el.type {
        case .action where char(0) == "!":
            ranges.append(NSRange(location: start, length: 1))
        case .sceneHeading where char(0) == "." && char(1) != ".":
            ranges.append(NSRange(location: start, length: 1))
        case .character where char(0) == "@":
            ranges.append(NSRange(location: start, length: 1))
        case .transition where char(0) == ">":
            ranges.append(NSRange(location: start, length: 1))
        case .centered:
            if char(0) == ">" { ranges.append(NSRange(location: start, length: 1)) }
            var j = end - 1
            while j > start {
                let c = ns.substring(with: NSRange(location: j, length: 1))
                if c == " " || c == "\t" { j -= 1 } else { break }
            }
            if j > start, ns.substring(with: NSRange(location: j, length: 1)) == "<" {
                ranges.append(NSRange(location: j, length: 1))
            }
        default:
            break
        }
        return ranges
    }

    /// Hides emphasis delimiters and applies bold / italic / underline to the inner text.
    private static func applyEmphasis(_ out: NSMutableAttributedString, raw: String, full: NSRange) {
        func forEach(_ pattern: String, _ body: (NSTextCheckingResult) -> Void) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            re.enumerateMatches(in: raw, range: full) { m, _, _ in if let m { body(m) } }
        }
        func hideDelims(_ m: NSTextCheckingResult, _ len: Int) {
            let r = m.range
            out.addAttributes(hiddenAttrs, range: NSRange(location: r.location, length: len))
            out.addAttributes(hiddenAttrs, range: NSRange(location: r.location + r.length - len, length: len))
        }
        // Bold: **text**
        forEach(#"\*\*(.+?)\*\*"#) { m in
            hideDelims(m, 2)
            out.addAttribute(.font, value: Screenplay.boldFont, range: m.range(at: 1))
        }
        // Italic: *text* (single asterisks)
        forEach(#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#) { m in
            hideDelims(m, 1)
            out.addAttribute(.font, value: NSFont(name: "Courier-Oblique", size: 12) ?? Screenplay.font,
                             range: m.range(at: 1))
        }
        // Underline: _text_
        forEach(#"(?<!_)_([^_\n]+?)_(?!_)"#) { m in
            hideDelims(m, 1)
            out.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
        }
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
