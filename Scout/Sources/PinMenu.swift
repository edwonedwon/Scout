import SwiftUI
import ScoutKit

enum PinMenuOrigin { case sidebar, grid, map }

/// The actions a pin's right-click menu can perform, pre-bound to a specific pin. A nil closure
/// omits that item. Each surface builds this; the ORDER, titles, and which items show is defined
/// once in `pinMenuEntries`, then rendered as SwiftUI buttons (sidebar/grid) or an NSMenu (map).
struct PinMenuActions {
    var isFlagged: Bool
    var toggleFlag: () -> Void
    var revealInFinder: (() -> Void)?
    var revealInList: (() -> Void)?
    var revealInGrid: (() -> Void)?
    var revealOnMap: (() -> Void)?
    var delete: () -> Void
}

struct PinMenuEntry: Identifiable {
    let id = UUID()
    var separatorBefore = false
    let title: String
    let systemImage: String
    var destructive = false
    let action: () -> Void
}

/// THE single source of menu structure/order/titles for a pin. Surface-specific reveal options
/// are chosen by `origin`; everything else (Flag, Reveal in Finder, Delete) is identical.
func pinMenuEntries(_ origin: PinMenuOrigin, _ a: PinMenuActions) -> [PinMenuEntry] {
    var e: [PinMenuEntry] = []
    e.append(.init(title: a.isFlagged ? "Unflag" : "Flag as Filming Location",
                   systemImage: a.isFlagged ? "flag.slash" : "flag", action: a.toggleFlag))
    if let f = a.revealInFinder {
        e.append(.init(title: "Reveal in Finder", systemImage: "folder", action: f))
    }
    // Surface-specific "Reveal …" options, right below Reveal in Finder.
    switch origin {
    case .sidebar:
        if let g = a.revealInGrid { e.append(.init(title: "Reveal in Photo Grid", systemImage: "square.grid.2x2", action: g)) }
        if let m = a.revealOnMap  { e.append(.init(title: "Reveal on Map", systemImage: "map", action: m)) }
    case .grid:
        if let l = a.revealInList { e.append(.init(title: "Reveal in List", systemImage: "list.bullet", action: l)) }
        if let m = a.revealOnMap  { e.append(.init(title: "Reveal on Map", systemImage: "map", action: m)) }
    case .map:
        if let g = a.revealInGrid { e.append(.init(title: "Reveal in Photo Grid", systemImage: "square.grid.2x2", action: g)) }
        if let l = a.revealInList { e.append(.init(title: "Reveal in List", systemImage: "list.bullet", action: l)) }
    }
    e.append(.init(separatorBefore: true, title: "Move to Trash", systemImage: "trash", destructive: true, action: a.delete))
    return e
}

/// SwiftUI renderer (sidebar + photo grid). The map renders the same entries as an NSMenu.
@ViewBuilder
func pinContextMenuItems(_ origin: PinMenuOrigin, _ actions: PinMenuActions) -> some View {
    ForEach(pinMenuEntries(origin, actions)) { entry in
        if entry.separatorBefore { Divider() }
        Button(role: entry.destructive ? .destructive : nil, action: entry.action) {
            Label(entry.title, systemImage: entry.systemImage)
        }
    }
}

/// Caches the two expensive pieces of `rebuildPinCaches` so a visibility toggle (which
/// changes neither a pin's data nor a list's membership) reuses results instead of
/// recomputing them for thousands of pins on the main thread:
///   • `asScoutLocation()` — does a per-pin disk stat (`isReadableFile`) via fullResImages.
///   • `proximityOrdered()` — an O(n²) nearest-neighbour walk per list section.
/// Both are keyed by a cheap content signature, so any real change (rotation, new photos,
/// moved/added/removed pins, reorder) self-invalidates while a pure show/hide hits the cache.
/// Held by the view via plain @State: mutating its internal dictionaries does NOT re-render
