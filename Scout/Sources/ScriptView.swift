import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The third center-panel mode (Map / Photos / Script). Renders the active script's fountain
/// text as readable, styled, scrollable text. (Highlight/scene-linking comes in a later phase.)
struct ScriptView: View {
    let script: ScriptData?

    var body: some View {
        Group {
            if let script {
                #if os(macOS)
                ScriptTextRepresentable(text: script.rawText)
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
    static let background = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1))
    #else
    static let background = Color.black
    #endif
}

#if os(macOS)
/// Read-only `NSTextView` (selection enabled) showing the fountain text styled per element.
struct ScriptTextRepresentable: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        tv.textContainerInset = NSSize(width: 28, height: 28)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        context.coordinator.apply(text, to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard context.coordinator.lastText != text else { return }
        context.coordinator.apply(text, to: tv)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastText: String = "\u{0}"   // sentinel so the first apply always runs
        func apply(_ text: String, to tv: NSTextView) {
            tv.textStorage?.setAttributedString(FountainRenderer.attributedString(text))
            lastText = text
        }
    }
}

/// Builds a styled `NSAttributedString` from parsed fountain elements. Readable screenplay-ish
/// styling (monospace, bold scene headings, indented dialogue, right-aligned transitions) —
/// not page-accurate pagination.
enum FountainRenderer {
    private static let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private static let textColor = NSColor(calibratedWhite: 0.90, alpha: 1)
    private static let dimColor  = NSColor(calibratedWhite: 0.60, alpha: 1)

    static func attributedString(_ raw: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for el in FountainParser.parse(raw) {
            guard el.type != .blank else { continue }
            let (font, color, para) = style(for: el.type)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: para
            ]
            let line = el.type == .pageBreak ? "— — —" : el.text
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
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
            return (NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
                    NSColor.controlAccentColor, p)
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
