import SwiftUI
import ScoutKit
import UniformTypeIdentifiers

// Soft-delete, trash, restore, and purge logic.
extension ProjectDetailView {
    /// Soft-deletes a photo by moving it to the Trash (keeps its list/project membership so
    /// it can be restored in place). Pushes an undo batch so ⌘Z brings it back.
    func deletePin(_ pin: PinVM) {
        trashPins([pin])
    }

    /// Moves photos to the Trash and records an undo batch. Lists are never trashed —
    /// they're not photos — so this only touches pins.
    func trashPins(_ pins: [PinVM]) {
        let live = pins.filter { $0.deletedAt == nil }
        guard !live.isEmpty else { return }
        let now = Date()
        for pin in live {
            pin.deletedAt = now
            selection.ids.remove(pin.uuid)
        }
        trashUndoStack.append(live.map { $0.id })
        normalizeOrder()
    }

    /// Deletes every currently-selected sidebar item. Photos go straight to the Trash
    /// (undoable). Lists are NEVER deleted without an explicit confirmation — if the selection
    /// includes any list, we stash everything and show a confirm dialog first.
    func deleteSelectedItems() {
        let ids = selection.ids
        guard !ids.isEmpty else { return }
        var pins: [PinVM] = []
        var lists: [ListVM] = []
        for id in ids {
            if let pin = findPin(uuid: id) {
                pins.append(pin)
            } else if let list = findList(uuid: id) {
                lists.append(list)
            }
        }
        if lists.isEmpty {
            // Photos only — trash immediately (undoable, no confirm needed).
            selection.ids = []
            trashPins(pins)
        } else {
            // Any list selected → confirm before trashing.
            listsPendingDelete = lists
            pinsPendingDelete = pins
            showDeleteListConfirm = true
        }
    }

    /// Requests deletion of a single list (from its row's context menu) — always confirms.
    func requestDeleteList(_ list: ListVM) {
        listsPendingDelete = [list]
        pinsPendingDelete = []
        showDeleteListConfirm = true
    }

    /// Carries out a confirmed delete: lists (and any co-selected photos) move to the Trash.
    func confirmDeletePending() {
        for list in listsPendingDelete { trashList(list) }
        let pins = pinsPendingDelete
        listsPendingDelete = []
        pinsPendingDelete = []
        selection.ids = []
        if !pins.isEmpty { trashPins(pins) } else { normalizeOrder() }
    }

    /// Human-readable summary for the delete-confirmation dialog.
    var deleteConfirmMessage: String {
        let listCount = listsPendingDelete.count
        // Count photos that will go to the trash with the lists (their pins + descendants).
        let listPhotoCount = listsPendingDelete.reduce(0) { $0 + photoCount(in: $1) }
        let extraPhotos = pinsPendingDelete.count
        let listWord = listCount == 1 ? "list" : "lists"
        var parts = ["\(listCount) \(listWord)"]
        let totalPhotos = listPhotoCount + extraPhotos
        if totalPhotos > 0 { parts.append("\(totalPhotos) photo\(totalPhotos == 1 ? "" : "s")") }
        return "Move \(parts.joined(separator: " and ")) to the Trash? Items are removed permanently after 30 days."
    }

    /// Live (non-trashed) photo count in a list, including its descendant child lists.
    func photoCount(in list: ListVM) -> Int {
        list.pins.filter { $0.deletedAt == nil }.count
            + list.childLists.reduce(0) { $0 + photoCount(in: $1) }
    }

    /// Soft-deletes a list (and, for folders, its child lists) to the Trash. The list's photos
    /// travel with it implicitly — they stay attached, hidden because their list is trashed.
    func trashList(_ list: ListVM) {
        let now = Date()
        func mark(_ l: ListVM) {
            if l.deletedAt == nil { l.deletedAt = now }
            activeListIDs.remove(l.id)
            selection.ids.remove(l.uuid)
            for child in l.childLists { mark(child) }
        }
        mark(list)
        normalizeOrder()
    }

    /// Restores a trashed list (and its trashed child lists) from the Trash.
    func restoreList(_ list: ListVM) {
        func clear(_ l: ListVM) {
            l.deletedAt = nil
            for child in l.childLists where child.deletedAt != nil { clear(child) }
        }
        clear(list)
        normalizeOrder()
    }

    /// Permanently deletes a trashed list and everything under it (pins + child lists cascade).
    func purgeList(_ list: ListVM) {
        Task { try? await ScoutStore.shared.purgeList(id: list.id) }   // cascade removes pins + child lists
    }

    // MARK: - Trash

    /// All trashed photos in this project (top-level, or individually trashed inside a LIVE
    /// list). Photos inside a trashed *list* are excluded — they travel with their list and
    /// show under it in the Trash, not as loose photos.
    var trashedPins: [PinVM] {
        var pins = project.importedPhotos.filter { $0.deletedAt != nil }
        for list in project.lists where list.deletedAt == nil {
            pins += list.pins.filter { $0.deletedAt != nil }
        }
        return pins.sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Trashed lists shown in the Trash — only the root of each trashed subtree (a trashed
    /// child whose parent is also trashed is hidden under its parent), newest first.
    var trashedLists: [ListVM] {
        project.lists
            .filter { $0.deletedAt != nil && ($0.parentList == nil || $0.parentList?.deletedAt == nil) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    /// Restores a trashed photo back to wherever it lived.
    func restoreFromTrash(_ pin: PinVM) {
        pin.deletedAt = nil
        normalizeOrder()
    }

    /// ⌘Z — restores the most recent batch of trashed photos. Falls back to the single
    /// newest trashed photo so deletes made elsewhere (e.g. the carousel) are also undoable.
    func undoLastTrash() {
        if let batch = trashUndoStack.popLast() {
            for id in batch {
                if let pin = findPin(byID: id) { pin.deletedAt = nil }
            }
        } else if let latest = trashedPins.first {   // trashedPins is sorted newest-first
            latest.deletedAt = nil
        } else {
            return
        }
        normalizeOrder()
    }

    /// Permanently deletes a single trashed photo (right-click → Delete Permanently).
    func purgePin(_ pin: PinVM) {
        Task { try? await ScoutStore.shared.purgePin(id: pin.id) }
    }

    /// Empties the Trash — permanently deletes every trashed photo AND trashed list.
    func emptyTrash() {
        for pin in trashedPins { purgePin(pin) }
        for list in trashedLists { purgeList(list) }
    }

    /// Purges photos and lists that have been in the Trash longer than 30 days. Called on appear.
    func purgeExpiredTrash() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        for pin in trashedPins.filter({ ($0.deletedAt ?? .distantFuture) < cutoff }) { purgePin(pin) }
        for list in trashedLists.filter({ ($0.deletedAt ?? .distantFuture) < cutoff }) { purgeList(list) }
    }

    /// True when `id` is part of a multi-item selection (used to switch context-menu
    /// actions and labels between single-item and whole-selection delete).
    func isInMultiSelection(_ id: UUID) -> Bool {
        selection.ids.count > 1 && selection.ids.contains(id)
    }

    /// "Delete Photos (3)" when the selection is all photos/pins, else "Delete Items (3)".
    var deleteSelectionLabel: String {
        let allPhotos = selection.ids.allSatisfy { findPin(uuid: $0) != nil }
        return allPhotos ? "Delete Photos (\(selection.ids.count))"
                         : "Delete Items (\(selection.ids.count))"
    }


    /// Trimmed search query; empty means no filtering.
}
