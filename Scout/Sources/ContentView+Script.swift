import SwiftUI
import MapKit
import ScoutKit

// Script scene-link assign/reveal, pin trash/move, photo caching.
extension ContentView {
    /// `m` pressed in Script mode with a selection → pick a list to assign that range to.
    func beginScriptAssign(_ range: NSRange) {
        pendingScriptRange = range
        showScriptListPicker = true
    }

    /// Right-click "Create new list and assign" → prompt for a name (pre-filled with the scene
    /// heading), make the list, and assign the range to it.
    func beginScriptAssignNewList(_ range: NSRange) {
        pendingScriptRange = range
        scriptNewListName = activeScript.flatMap {
            FountainParser.sceneHeading(in: $0.rawText, before: range.location)
        } ?? ""
        showScriptNewListSheet = true
    }

    /// Creates a new list in the open project and assigns the pending script range to it.
    func createListAndAssignScene(named name: String, parent: ListVM? = nil) {
        defer { showScriptNewListSheet = false; pendingScriptRange = nil; showScriptListPicker = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let project = openProject else { return }
        let colorHex = ListVM.palette[project.lists.count % ListVM.palette.count]

        // Determine parent + panelOrder (mirrors the sidebar's insert rules); sibling shifts
        // persist through the VM write-through setters.
        var parentId: String? = nil
        var panelOrder = 0
        if let parent {
            parentId = parent.id
            panelOrder = (parent.liveChildLists.map(\.panelOrder).max() ?? -1) + 1
        } else if let sel = selectedSidebarList {
            if !sel.liveChildLists.isEmpty {
                parentId = sel.id
                panelOrder = (sel.liveChildLists.map(\.panelOrder).max() ?? -1) + 1
            } else {
                parentId = sel.parentList?.id
                let siblings = sel.parentList?.liveChildLists
                    ?? project.lists.filter { $0.parentList == nil && $0.deletedAt == nil }
                for sibling in siblings where sibling.panelOrder > sel.panelOrder { sibling.panelOrder += 1 }
                panelOrder = sel.panelOrder + 1
            }
        } else {
            for existing in project.lists where existing.parentList == nil { existing.panelOrder += 1 }
            project.importedPhotos.forEach { $0.panelOrder += 1 }
            panelOrder = 0
        }

        let inputs = currentSceneLinkInputs()
        let projectId = project.id, pId = parentId, pOrder = panelOrder
        Task {
            if let listId = try? await ScoutStore.shared.createList(
                projectId: projectId, name: trimmed, colorHex: colorHex,
                parentListId: pId, panelOrder: pOrder), let inputs {
                insertSceneLink(inputs, listId: listId)
            }
        }
    }

    /// The list/folder currently selected in the sidebar (anchor first), if any.
    var selectedSidebarList: ListVM? {
        let id = selection.anchor ?? selection.ids.first
        guard let id else { return nil }
        return allLists.first { $0.uuid == id && $0.deletedAt == nil }
    }

    /// The script-highlight fields for the pending selection (computed once, inserted with a listId).
    struct SceneLinkInputs { let scriptId: String; let start: Int; let len: Int; let excerpt: String; let before: String; let after: String; let heading: String? }
    func currentSceneLinkInputs() -> SceneLinkInputs? {
        guard let range = pendingScriptRange, let script = activeScript else { return nil }
        let ns = script.rawText as NSString
        guard range.length > 0, range.location + range.length <= ns.length else { return nil }
        let excerpt = ns.substring(with: range)
        let beforeLen = min(40, range.location)
        let before = ns.substring(with: NSRange(location: range.location - beforeLen, length: beforeLen))
        let afterStart = range.location + range.length
        let after = ns.substring(with: NSRange(location: afterStart, length: min(40, ns.length - afterStart)))
        let heading = FountainParser.sceneHeading(in: script.rawText, before: range.location)
        return SceneLinkInputs(scriptId: script.id, start: range.location, len: range.length,
                               excerpt: excerpt, before: before, after: after, heading: heading)
    }
    func insertSceneLink(_ inp: SceneLinkInputs, listId: String) {
        Task { try? await ScoutStore.shared.createHighlight(
            scriptId: inp.scriptId, listId: listId, rangeStart: inp.start, rangeLength: inp.len,
            excerpt: inp.excerpt, contextBefore: inp.before, contextAfter: inp.after, sceneHeading: inp.heading) }
    }

    /// Creates a scene-link highlight linking the pending script range to the chosen list.
    func assignScriptSelection(to list: ListVM) {
        defer { pendingScriptRange = nil; showScriptListPicker = false }
        if let inp = currentSceneLinkInputs() { insertSceneLink(inp, listId: list.id) }
    }

    /// Deletes any HighlightVM(s) of the active script that overlap `range` (right-click
    /// "Remove Highlight"). Works regardless of whether the link's list still exists — the surest
    /// way to clear a stray highlight.
    func removeScriptHighlight(overlapping range: NSRange) {
        guard let script = activeScript, range.length > 0 else { return }
        let victims = allScriptHighlights.filter { h in
            guard h.script?.uuid == script.uuid else { return false }
            let hr = NSRange(location: h.rangeStart, length: h.rangeLength)
            return NSIntersectionRange(hr, range).length > 0
        }
        guard !victims.isEmpty else { return }
        for h in victims { Task { try? await ScoutStore.shared.deleteHighlight(id: h.id) } }
    }

    /// Opens a script highlight: switch to Script mode, show its script, scroll to & select it.
    /// A highlight in the script was clicked: select its linked list and reveal it (centered) in
    /// the sidebar. No-op if the offset isn't inside a highlight, or its list is gone/trashed.
    func selectListForScriptOffset(_ offset: Int) {
        guard let script = activeScript,
              let h = allScriptHighlights.first(where: {
                  $0.script?.uuid == script.uuid
                  && offset >= $0.rangeStart && offset < $0.rangeStart + $0.rangeLength
              }),
              let list = h.list, list.deletedAt == nil else { return }
        selection.ids = [list.uuid]
        selection.anchor = list.uuid
        revealListUUID = nil
        DispatchQueue.main.async { revealListUUID = list.uuid }
    }

    /// Selecting a list in the sidebar while the Script view is open scrolls the script to that
    /// list's earliest scene — same effect as clicking the list's little script-scene icon. No-op
    /// when not in script view or the list has no scene link.
    func scrollScriptToList(_ list: ListVM) {
        guard viewMode == .script else { return }
        guard let link = list.sceneLinks.min(by: { $0.rangeStart < $1.rangeStart }) else { return }
        openScriptHighlight(link)
    }

    func openScriptHighlight(_ highlight: HighlightVM) {
        guard let script = highlight.script else { return }
        activeScriptUUID = script.uuid
        withAnimation(.spring(duration: 0.3)) { viewMode = .script }
        // Reset first so re-opening the same highlight still triggers the scroll.
        scriptScrollTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            scriptScrollTarget = NSRange(location: highlight.rangeStart, length: highlight.rangeLength)
        }
    }

    /// "Reveal in Photo Grid": switch to the grid, scroll to the photo, and select it.
    func revealInGrid(_ uuid: UUID) {
        if photoViewer.isVisible { photoViewer.dismiss() }
        let wasPhotos = (viewMode == .photos)
        if !wasPhotos { withAnimation(.spring(duration: 0.3)) { viewMode = .photos } }
        selection.ids = [uuid]; selection.anchor = uuid
        // Reset the scroll target first so re-revealing the same photo still fires the grid's
        // onChange. Defer past the viewMode switch (whose onChange sets its own scroll target).
        gridScrollTargetID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasPhotos ? 0.05 : 0.35)) {
            gridScrollTargetID = uuid
            highlightedPinID = uuid
        }
    }

    /// "Reveal on Map": select the pin and center/zoom the map on it (switching to map view).
    func revealOnMap(_ uuid: UUID) {
        guard let pin = allPins.first(where: { $0.uuid == uuid }) else { return }
        selection.ids = [uuid]; selection.anchor = uuid
        zoomToPin(pin)
    }

    /// Soft-delete (trash) the given pins, updating selection and caches once.
    func trashPins(_ uuids: [UUID]) {
        let pins = allPins.filter { uuids.contains($0.uuid) && $0.deletedAt == nil }
        guard !pins.isEmpty else { return }
        let now = Date()
        for p in pins { p.deletedAt = now }
        selection.ids.subtract(uuids)
        rebuildPinCaches()
    }

    /// "Reveal in List": open the sidebar and ask it to expand the pin's list/folder chain and
    /// scroll to its row.
    func revealInList(_ uuid: UUID) {
        let wasClosed = !showProjectsPanel
        if wasClosed {
            withAnimation(.spring(duration: 0.3)) { showProjectsPanel = true }
        }
        // Re-set so onChange fires even when revealing the same pin twice in a row. When the
        // panel was closed it must first mount and restore its nav stack, so fire after the
        // open animation; otherwise a short hop is enough.
        revealInListUUID = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasClosed ? 0.4 : 0.05)) {
            revealInListUUID = uuid
        }
    }

    func deletePinFromCarousel(_ loc: ScoutLocation) {
        guard let pin = pin(byUUID: loc.id) else { return }
        pin.deletedAt = Date()
        rebuildPinCaches()
    }

    /// Delete-key handler for the grid/map (center panel). The sidebar has its own delete
    /// shortcut, but in grid/map mode the center panel is focused, so — exactly like the "m"
    /// and "u" shortcuts — ContentView needs its own. Trashes EVERY selected photo (the whole
    /// shared multi-selection), not just the highlighted one.
    func deleteSelectedPhotos() {
        trashPins(Array(selection.ids))
    }

    /// Debug "Find Duplicates": scans every live photo in the project for duplicates
    /// (same normalized filename, or same EXIF capture-time + GPS), then stashes the
    /// compressed copies to remove and shows a confirmation. The original large files are
    /// always kept; confirmed removals go to the Trash (recoverable, 30-day rule).
    func findDuplicates() {
        let plan = PhotoImportService.findDuplicates(in: Array(allPins))
        if plan.remove.isEmpty {
            DebugLogger.shared.log("No duplicates found across \(allPins.filter { $0.deletedAt == nil }.count) photos.",
                                   level: .info, tag: "Dedup")
            return
        }
        pendingDuplicateRemoval = plan.remove
        pendingDuplicateClusters = plan.clusters
        showDuplicateConfirm = true
    }

    /// Confirmed: move the previously-found duplicate copies to the Trash.
    func confirmRemoveDuplicates() {
        let now = Date()
        for pin in pendingDuplicateRemoval { pin.deletedAt = now }
        rebuildPinCaches()
        DebugLogger.shared.log("Moved \(pendingDuplicateRemoval.count) duplicate photo(s) to Trash across \(pendingDuplicateClusters) group(s); kept the original files.",
                               level: .success, tag: "Dedup")
        pendingDuplicateRemoval = []
        pendingDuplicateClusters = 0
    }

    /// Moves an existing pin out of wherever it lives and into `list`.
    func movePin(_ pin: PinVM, to list: ListVM) {
        // Bump existing pins down so the moved pin lands at the top.
        list.pins.forEach { $0.sortOrder += 1 }
        // Reassign in one store write: into the list, clear any project-top-level ownership.
        Task { try? await ScoutStore.shared.movePin(id: pin.id, toList: list.id, owningProjectId: nil, sortOrder: 0) }
    }

    /// Download a saved pin's photos to disk and capture its source links, so it displays
    /// offsline (never refetches) and shows its Google Maps / source link in the popover.
    func cachePhotos(pinId: String, from location: ScoutLocation) {
        let uuid = UUID(uuidString: pinId) ?? UUID()
        let placeId = location.googlePlaceId
        Task { @MainActor in
            let result = await PinPhotoStore.download(for: location, placeId: placeId, pinUUID: uuid)
            if !result.files.isEmpty {
                try? await ScoutStore.shared.setPinPhotoFiles(id: pinId, photoFiles: result.files, thumbnailFiles: [])
                // Push the freshly downloaded bytes to Storage so the pin's photo reaches other devices.
                await PhotoStorageService.shared.uploadLocalTiers(pinId: pinId, fullFiles: result.files, thumbnailFiles: [])
            }
            // googleMapsURL / sourceURL are captured at insert time from the location.
        }
    }
}
