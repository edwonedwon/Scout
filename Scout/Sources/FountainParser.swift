import Foundation

/// A minimal Fountain screenplay parser — enough to render a readable, styled script.
/// Not a full spec implementation (no title-page key parsing, dual dialogue, etc.); it
/// classifies each line so the Script view can style it. Each element keeps its character
/// range in the original text so future highlight features can map back to offsets.
enum FountainElementType {
    case sceneHeading
    case action
    case character
    case parenthetical
    case dialogue
    case transition
    case section          // # ...
    case synopsis         // = ...
    case centered         // > ... <
    case pageBreak        // ===
    case titlePage        // leading "Key: Value" block
    case blank
}

struct FountainElement {
    let type: FountainElementType
    /// Display text (markers like leading `.`/`>`/`@`/`!` stripped).
    let text: String
    /// Character range of the source line(s) in the original raw text.
    let range: NSRange
}

enum FountainParser {
    /// Scene-heading prefixes (case-insensitive), per Fountain.
    private static let sceneoPrefixes = ["INT.", "EXT.", "EST.", "INT./EXT.", "INT/EXT.", "I/E.",
                                         "INT ", "EXT ", "EST ", "INT./EXT ", "INT/EXT "]

    static func parse(_ raw: String) -> [FountainElement] {
        // Split into lines while tracking each line's character range in `raw`. Use a simple
        // components split (can't infinite-loop, unlike a hand-rolled lineRange walk) and track
        // the running NSString offset so ranges map back to `raw` for later highlight features.
        var lines: [(text: String, range: NSRange)] = []
        var loc = 0
        for part in raw.components(separatedBy: "\n") {
            let nsLen = (part as NSString).length
            lines.append((part.trimmingCharacters(in: .whitespacesAndNewlines),
                          NSRange(location: loc, length: nsLen)))
            loc += nsLen + 1   // + the consumed "\n"
        }

        var elements: [FountainElement] = []

        // Title page: leading run of "Key: Value" lines (and their indented continuations)
        // before the first blank line, only if the very first line looks like a key.
        var start = 0
        if let first = lines.first?.text, isTitlePageKey(first) {
            while start < lines.count, !lines[start].text.isEmpty {
                let l = lines[start]
                elements.append(FountainElement(type: .titlePage, text: l.text, range: l.range))
                start += 1
            }
        }

        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            let prevBlank = (i == start) || lines[i - 1].text.trimmingCharacters(in: .whitespaces).isEmpty
            let nextNonBlank = (i + 1 < lines.count) && !lines[i + 1].text.trimmingCharacters(in: .whitespaces).isEmpty

            if trimmed.isEmpty {
                elements.append(FountainElement(type: .blank, text: "", range: line.range))
                i += 1; continue
            }
            // Page break: 3+ '='
            if trimmed.allSatisfy({ $0 == "=" }) && trimmed.count >= 3 {
                elements.append(FountainElement(type: .pageBreak, text: "", range: line.range)); i += 1; continue
            }
            // Section / Synopsis
            if trimmed.hasPrefix("#") {
                elements.append(FountainElement(type: .section, text: String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces), range: line.range)); i += 1; continue
            }
            if trimmed.hasPrefix("=") {
                elements.append(FountainElement(type: .synopsis, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), range: line.range)); i += 1; continue
            }
            // Centered: > text <
            if trimmed.hasPrefix(">"), trimmed.hasSuffix("<") {
                let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                elements.append(FountainElement(type: .centered, text: inner, range: line.range)); i += 1; continue
            }
            // Forced markers
            if trimmed.hasPrefix("!") {
                elements.append(FountainElement(type: .action, text: String(trimmed.dropFirst()), range: line.range)); i += 1; continue
            }
            if trimmed.hasPrefix(".") && !trimmed.hasPrefix("..") {
                elements.append(FountainElement(type: .sceneHeading, text: String(trimmed.dropFirst()).uppercased(), range: line.range)); i += 1; continue
            }
            if trimmed.hasPrefix("@") {
                elements.append(FountainElement(type: .character, text: String(trimmed.dropFirst()), range: line.range))
                i += 1
                i = consumeDialogue(lines, from: i, into: &elements)
                continue
            }
            if trimmed.hasPrefix(">") {   // forced transition
                elements.append(FountainElement(type: .transition, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces).uppercased(), range: line.range)); i += 1; continue
            }
            // Scene heading by prefix
            if isSceneHeading(trimmed) {
                elements.append(FountainElement(type: .sceneHeading, text: trimmed.uppercased(), range: line.range)); i += 1; continue
            }
            // Transition: ALL CAPS ending in "TO:" with a blank line before.
            if prevBlank, isTransition(trimmed) {
                elements.append(FountainElement(type: .transition, text: trimmed, range: line.range)); i += 1; continue
            }
            // Character cue: ALL CAPS line, blank before, dialogue after.
            if prevBlank, nextNonBlank, isCharacter(trimmed) {
                elements.append(FountainElement(type: .character, text: trimmed, range: line.range))
                i += 1
                i = consumeDialogue(lines, from: i, into: &elements)
                continue
            }
            // Default: action.
            elements.append(FountainElement(type: .action, text: line.text, range: line.range))
            i += 1
        }
        return elements
    }

    /// The nearest scene heading at or before `location` (character offset into `raw`), for
    /// labelling a highlight. nil if there's no preceding scene heading.
    static func sceneHeading(in raw: String, before location: Int) -> String? {
        var heading: String? = nil
        for el in parse(raw) where el.type == .sceneHeading {
            if el.range.location <= location { heading = el.text } else { break }
        }
        return heading
    }

    /// Consumes the dialogue block (parentheticals + dialogue lines) until a blank line.
    private static func consumeDialogue(_ lines: [(text: String, range: NSRange)], from start: Int,
                                        into elements: inout [FountainElement]) -> Int {
        var i = start
        while i < lines.count {
            let t = lines[i].text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { break }
            if t.hasPrefix("(") && t.hasSuffix(")") {
                elements.append(FountainElement(type: .parenthetical, text: t, range: lines[i].range))
            } else {
                elements.append(FountainElement(type: .dialogue, text: lines[i].text, range: lines[i].range))
            }
            i += 1
        }
        return i
    }

    private static func isSceneHeading(_ s: String) -> Bool {
        let upper = s.uppercased()
        return sceneoPrefixes.contains { upper.hasPrefix($0) }
    }

    private static func isTransition(_ s: String) -> Bool {
        guard s == s.uppercased(), s.count > 1 else { return false }
        return s.hasSuffix("TO:")
    }

    /// A character cue: uppercase, not ending with sentence punctuation, may carry a (V.O.) etc.
    private static func isCharacter(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        // Strip a trailing extension like "(V.O.)" before the uppercase test.
        let base = s.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return false }
        // Must contain a letter and be all-uppercase (no lowercase letters).
        let hasLetter = base.contains { $0.isLetter }
        let hasLower = base.contains { $0.isLowercase }
        return hasLetter && !hasLower
    }

    private static func isTitlePageKey(_ s: String) -> Bool {
        // e.g. "Title:", "Credit:", "Author:", "Draft date:" — a word(s) then a colon.
        guard let colon = s.firstIndex(of: ":") else { return false }
        let key = s[..<colon]
        return !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isWhitespace }
    }
}
