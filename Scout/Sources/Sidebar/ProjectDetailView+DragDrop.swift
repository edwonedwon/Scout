import SwiftUI
import ScoutKit
import UniformTypeIdentifiers

// Drag/drop, move, and reorder logic for sidebar items.
extension ProjectDetailView {
    // Drag-start helpers. Each records the drag kind (so list rows can suppress the between-
    // lists insertion line for photo drags) and returns the payload provider. Kept as small
    // functions so the (already large) sidebar view body stays type-checkable.
    func beginItemDrag(_ item: SidebarItem) -> NSItemProvider {
        SidebarDragState.shared.kind = item.dragKind
        return NSItemProvider(object: item.dragID as NSString)
    }
    func beginPhotoDrag(_ payload: String) -> NSItemProvider {
        SidebarDragState.shared.kind = .photo
        return NSItemProvider(object: payload as NSString)
    }
    func beginListDrag(_ payload: String) -> NSItemProvider {
        SidebarDragState.shared.kind = .list
        return NSItemProvider(object: payload as NSString)
    }

    /// Drop onto a pin row INSIDE a list: reorder there (before/after the row) or import files.
    /// `beforeNeighbor` is the pin immediately above `target` (nil if `target` is first), used to
    /// place the dropped photo correctly for a `.before` drop.
    func reorderPinDrop(_ providers: [NSItemProvider], list: ListVM,
                                target: PinVM, beforeNeighbor: PinVM?,
                                mode: DropMode) -> Bool {
        if tryImportDrop(providers, into: list) { return true }
        let after: PinVM? = (mode == .after) ? target : beforeNeighbor
        return loadDropPin(providers, intoList: list, afterPin: after)
    }

    /// Removes a pin from wherever it currently lives (list or top-level).
    func detach(_ pin: PinVM) {
        Task { try? await ScoutStore.shared.movePin(id: pin.id, toList: nil, owningProjectId: nil) }
    }

    // MARK: - Drop loading

    /// Loads drag payload from providers and dispatches to handleDrop on main actor.
    func loadDrop(_ providers: [NSItemProvider], onto target: SidebarItem) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                // Grid photo drag(s) onto a list header: move the pin(s) into the list.
                // Handles both single "photo:<uuid>" and multi "photos:<uuid>,..." payloads,
                // resolving pins directly (they may live inside another list, so they aren't
                // top-level sidebar items that handleDrop's resolve() could find).
                if case .list(let list) = target,
                   dragID.hasPrefix("photo:") || dragID.hasPrefix("photos:") {
                    if dragID.hasPrefix("photos:") {
                        // Grid multi-drag: move exactly the pins named in the payload.
                        let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                        movePins(uuids.compactMap { findPin(uuid: $0) }, intoList: list)
                    } else {
                        // Single "photo:" (grid single or sidebar loose photo) keeps the
                        // sidebar-selection-expanding path.
                        if let pin = findPin(uuid: String(dragID.dropFirst(6))) {
                            movePinsToList(pin, intoList: list)
                        }
                    }
                } else {
                    _ = handleDrop(dragID, onto: target)
                }
            }
        }
        return true
    }

    /// Moves a dragged item to the top/bottom of the sidebar.
    /// Handles list:, photo:, and pin: payloads.
    func loadDropToTopLevel(_ providers: [NSItemProvider], atTop: Bool) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                // List reorder: move to top or bottom.
                if dragID.hasPrefix("list:") {
                    let uuid = String(dragID.dropFirst(5))
                    guard let list = project.lists.first(where: { $0.uuid.uuidString == uuid }) else { return }
                    list.panelOrder = atTop ? -1 : sidebarItems.count + 1
                    normalizeOrder()
                    return
                }
                // Photo reorder: move to top or bottom (when already top-level).
                if dragID.hasPrefix("photo:") {
                    let uuid = String(dragID.dropFirst(6))
                    if let pin = project.importedPhotos.first(where: { $0.uuid.uuidString == uuid }) {
                        pin.panelOrder = atTop ? -1 : sidebarItems.count + 1
                        normalizeOrder()
                        return
                    }
                }
                // Pin dragged out of a list to top/bottom.
                let uuid: String
                if dragID.hasPrefix("pin:") { uuid = String(dragID.dropFirst(4)) }
                else if dragID.hasPrefix("photo:") { uuid = String(dragID.dropFirst(6)) }
                else { return }
                guard let primaryPin = findPin(uuid: uuid) else { return }
                guard primaryPin.list != nil else { return } // already top-level, nothing to do

                // If the dragged pin is part of a multi-selection, move all selected pins.
                var pinsToMove: [PinVM] = [primaryPin]
                if selection.contains(primaryPin.uuid) {
                    for id in selection.ids where id != primaryPin.uuid {
                        if let p = findPin(uuid: id), p.list != nil { pinsToMove.append(p) }
                    }
                }
                let pid = project.id
                for pin in pinsToMove {
                    pin.panelOrder = atTop ? -1 : sidebarItems.count + 1   // write-through
                    Task { try? await ScoutStore.shared.movePin(id: pin.id, toList: nil, owningProjectId: pid) }
                }
                normalizeOrder()
            }
        }
        return true
    }

    /// Core move: relocates EXACTLY `pins` into `list`, with no selection expansion.
    /// Use this for grid drags — their payload ("photos:a,b,c") already names every dragged
    /// photo. Routing those through `movePinsToList` instead re-expanded each pin via the
    /// SIDEBAR selection (a different selection from the grid's), pulling in unrelated pins —
    /// that was the "shift-select 3, list count jumps by 5–6" drag bug.
    func movePins(_ pins: [PinVM], intoList list: ListVM, afterPin: PinVM? = nil) {
        // Only pins not already in the target list. De-dupe by identity so a payload that
        // accidentally repeats an id can't move (or count) the same pin twice.
        var seen = Set<String>()
        // De-dupe only. Do NOT skip pins already in `list`: a drop onto a row in the SAME list
        // is a reorder, and the sortOrder logic below repositions them correctly (detach +
        // re-add). Skipping same-list pins made reordering within a list a silent no-op.
        let moving = pins.filter { seen.insert($0.id).inserted }
        guard !moving.isEmpty else { return }
        // Compute the final order purely via sortOrder. Existing members (excluding the just-
        // moved ones) keep their order; the moved pins go after `afterPin`, else to the front.
        let movingIDs = Set(moving.map(\.id))
        var ordered = list.pins
            .filter { !movingIDs.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
        if let after = afterPin, moving.count == 1,
           let idx = ordered.firstIndex(where: { $0.id == after.id }) {
            ordered.insert(contentsOf: moving, at: idx + 1)
        } else {
            ordered.insert(contentsOf: moving, at: 0)
        }
        // One store write per pin: moved pins are reassigned into the list at their final index;
        // existing members just get their new sortOrder. The watch update refreshes the graph.
        let listId = list.id
        Task {
            for (i, p) in ordered.enumerated() {
                if movingIDs.contains(p.id) {
                    try? await ScoutStore.shared.movePin(id: p.id, toList: listId, owningProjectId: nil, sortOrder: i)
                } else {
                    try? await ScoutStore.shared.setPinSortOrder(id: p.id, order: i)
                }
            }
        }
        normalizeOrder()
    }

    /// Sidebar single-pin/row drag: moves `primaryPin` PLUS any other pins selected in the
    /// SIDEBAR into `list`. Only for sidebar drags ("pin:"/"photo:" rows), where one dragged
    /// row should carry the whole sidebar selection. Grid drags must use `movePins` instead.
    func movePinsToList(_ primaryPin: PinVM, intoList list: ListVM, afterPin: PinVM? = nil) {
        var pins: [PinVM] = [primaryPin]
        if selection.contains(primaryPin.uuid) {
            for id in selection.ids where id != primaryPin.uuid {
                if let pin = findPin(uuid: id) { pins.append(pin) }
            }
        }
        movePins(pins, intoList: list, afterPin: afterPin)
    }

    /// Moves a pin (and any other selected pins) out of its list into Uncategorized (loose).
    func moveSelectedPinsToUncategorized(primary: PinVM) {
        var pins: [PinVM] = [primary]
        if selection.contains(primary.uuid) {
            for id in selection.ids where id != primary.uuid {
                if let p = findPin(uuid: id) { pins.append(p) }
            }
        }
        for pin in pins { movePinToUncategorized(pin) }
    }

    /// Detaches a single pin from wherever it lives and makes it a loose (Uncategorized) photo.
    func movePinToUncategorized(_ pin: PinVM) {
        guard pin.list != nil else { return }   // already loose
        let pid = project.id
        pin.panelOrder = (loosePhotos.map(\.panelOrder).max() ?? -1) + 1   // write-through
        Task { try? await ScoutStore.shared.movePin(id: pin.id, toList: nil, owningProjectId: pid) }
        normalizeOrder()
    }

    /// Finds a pin anywhere in the project by its String.
    func findPin(byID id: String) -> PinVM? {
        if let p = project.importedPhotos.first(where: { $0.id == id }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.id == id }) { return p }
        }
        return nil
    }

    /// Loads drag payload and moves the pin into a list, optionally after a specific pin.
    func loadDropPin(_ providers: [NSItemProvider], intoList list: ListVM, afterPin: PinVM? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                if dragID.hasPrefix("photos:") {
                    // Grid multi-drag: move exactly the listed pins, no selection expansion.
                    let uuids = dragID.dropFirst(7).split(separator: ",").map(String.init)
                    movePins(uuids.compactMap { findPin(uuid: $0) }, intoList: list, afterPin: afterPin)
                    return
                }
                let uuid: String
                if dragID.hasPrefix("pin:") { uuid = String(dragID.dropFirst(4)) }
                else if dragID.hasPrefix("photo:") { uuid = String(dragID.dropFirst(6)) }
                else { return }
                guard let pin = findPin(uuid: uuid) else { return }
                movePinsToList(pin, intoList: list, afterPin: afterPin)
            }
        }
        return true
    }

    // MARK: - Drop handling

    /// Central drop handler for top-level sidebar items.
    func handleDrop(_ dragID: String, onto target: SidebarItem, after: Bool = false) -> Bool {
        // Pin dragged from inside a list onto a top-level target.
        if dragID.hasPrefix("pin:") {
            let uuid = String(dragID.dropFirst(4))
            guard let pin = findPin(uuid: uuid) else { return false }
            switch target {
            case .list(let list):
                // Move pin (and any other selected pins) into this list.
                if pin.list?.id == list.id { return false }
                movePinsToList(pin, intoList: list)
            case .photo(let targetPin):
                // Move out to top-level, placed near the target photo.
                let pid = project.id
                pin.panelOrder = targetPin.panelOrder   // write-through
                Task { try? await ScoutStore.shared.movePin(id: pin.id, toList: nil, owningProjectId: pid) }
                normalizeOrder()
            case .uncategorized:
                // Dropping a list pin onto Uncategorized removes it from its list.
                moveSelectedPinsToUncategorized(primary: pin)
            }
            return true
        }

        // A nested list dragged onto a top-level row → unnest it to the top level, ordered
        // next to the target. (resolve() only finds top-level items, so handle lists first.)
        if dragID.hasPrefix("list:") {
            let uuid = String(dragID.dropFirst(5))
            if let list = project.lists.first(where: { $0.uuid.uuidString == uuid }),
               list.parentList != nil {
                Task { try? await ScoutStore.shared.setListParent(id: list.id, parentListId: nil) }
                reorderToTopLevel(list, near: target, after: after)
                return true
            }
        }

        // Top-level item dragged onto another top-level item.
        guard let dragged = resolve(dragID) else { return false }
        if dragged.id == target.id { return false }

        // Top-level photo dragged onto a list → move into list (with multi-select support).
        if case .photo(let pin) = dragged, case .list(let list) = target, !after {
            movePinsToList(pin, intoList: list)
            return true
        }

        // Otherwise reorder.
        reorder(dragged, before: target, after: after)
        return true
    }

    /// Re-inserts a now-top-level model (e.g. a just-unnested list) next to `target`.
    func reorderToTopLevel(_ list: ListVM, near target: SidebarItem, after: Bool) {
        rebuildSidebarItems()
        reorder(.list(list), before: target, after: after)
    }

    /// Reorders `dragged` next to `target`. Inserts before the target row (or after it when
    /// `after` is true), so every slot — including just below the last row — is reachable.
    func reorder(_ dragged: SidebarItem, before target: SidebarItem, after: Bool = false) {
        var items = sidebarItems
        guard let from = items.firstIndex(where: { $0.id == dragged.id }) else { return }
        let moving = items.remove(at: from)
        guard let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.insert(moving, at: after ? to + 1 : to)
        for (i, item) in items.enumerated() {
            switch item {
            case .photo(let p):            p.panelOrder = i
            case .list(let l):             l.panelOrder = i
            case .uncategorized(let proj): proj.uncategorizedPanelOrder = i
            }
        }
        // Rebuild the cached sidebar items so the new panelOrder is reflected on screen —
        // writing panelOrder alone doesn't re-sort the @State-cached display array.
        rebuildSidebarItems()
    }
}
