// IOSStoreSupport.swift — iOS-specific computed helpers on the store VMs (migration plan P2).
//
// The iOS browse tree (ScoutIOSApp / IOSContentTabs / IOSMapTab) reads ProjectVM/ListVM/PinVM, the
// same store-backed adapter the Mac UI uses. These extensions mirror the display helpers that used
// to hang off the Core Data entities so the view bodies stay a near-mechanical swap.

#if os(iOS)
import SwiftUI
import ScoutKit

extension ProjectVM {
    /// Top-level lists (not nested), in panel order, excluding trashed.
    var topLevelLists: [ListVM] {
        liveLists.filter { $0.parentListId == nil }.sorted { $0.panelOrder < $1.panelOrder }
    }
    /// Every live list id — used to seed "all visible" on the map.
    var allListIDs: Set<UUID> { Set(liveLists.map(\.uuid)) }
    /// Pins belonging to the lists currently toggled visible.
    func visiblePins(_ visible: Set<UUID>) -> [PinVM] {
        liveLists.filter { visible.contains($0.uuid) }.flatMap { $0.livePins }
    }
    /// All pins in the project (for default map framing).
    var allMapPins: [PinVM] { liveLists.flatMap { $0.livePins } + livePhotos }
    var pinCount: Int { allMapPins.count }

    /// Pins in the exact order the iOS photo grid lays them out: top-level lists in panel order,
    /// each folder expanded to its children, every list's pins in sort order. Drives thumbnail
    /// prefetch priority so the top of the grid (what the user sees first) downloads first.
    /// `visibleOnly` restricts to lists currently toggled visible (so changing visibility
    /// re-prioritizes the download to match what's actually shown).
    func photoGridPins(visible: Set<UUID>? = nil) -> [PinVM] {
        func shown(_ list: ListVM) -> Bool { visible == nil || visible!.contains(list.uuid) }
        var out: [PinVM] = []
        for list in topLevelLists {
            if list.isFolder {
                for child in list.iosSortedChildren where !child.livePins.isEmpty && shown(child) {
                    out += child.proximitySortedPins
                }
                if !list.livePins.isEmpty && shown(list) { out += list.proximitySortedPins }
            } else if !list.livePins.isEmpty && shown(list) {
                out += list.proximitySortedPins
            }
        }
        // Visible lists first (above); append the rest so everything still eventually downloads.
        if visible != nil {
            let shownIDs = Set(out.map(\.id))
            out += photoGridPins().filter { !shownIDs.contains($0.id) }
        }
        return out
    }
}

extension ListVM {
    var iosSortedChildren: [ListVM] { liveChildLists.sorted { $0.panelOrder < $1.panelOrder } }
    var sortedPins: [PinVM] { livePins.sorted { $0.sortOrder < $1.sortOrder } }
    var isFolder: Bool { !liveChildLists.isEmpty }

    /// Pins ordered so geographically-close photos sit next to each other in the grid, via a Morton
    /// (Z-order space-filling curve) over their coordinates within this list's bounding box. Nearby
    /// points get nearby codes, so the grid reads as spatial clusters rather than import order. Pins
    /// without a location keep to the end in their normal sortOrder. Only reorders *within* a list —
    /// the section order (and the sidebar order) is unchanged.
    var proximitySortedPins: [PinVM] {
        let pins = sortedPins
        let located = pins.filter { $0.latitude != 0 || $0.longitude != 0 }
        let unlocated = pins.filter { $0.latitude == 0 && $0.longitude == 0 }
        guard located.count > 2 else { return located + unlocated }

        let lats = located.map(\.latitude), lons = located.map(\.longitude)
        let minLat = lats.min()!, minLon = lons.min()!
        let latSpan = max(lats.max()! - minLat, 1e-9), lonSpan = max(lons.max()! - minLon, 1e-9)
        let keyed = located.map { pin -> (UInt32, PinVM) in
            let x = UInt32(max(0, min(65535, (pin.longitude - minLon) / lonSpan * 65535)))
            let y = UInt32(max(0, min(65535, (pin.latitude - minLat) / latSpan * 65535)))
            return (Self.interleaveBits(x) | (Self.interleaveBits(y) << 1), pin)
        }
        return keyed.sorted { $0.0 < $1.0 }.map(\.1) + unlocated
    }

    /// Spread the low 16 bits of `v` so bit i lands at position 2i (Morton/Z-order interleave).
    private static func interleaveBits(_ v: UInt32) -> UInt32 {
        var x = v & 0x0000_FFFF
        x = (x | (x << 8)) & 0x00FF_00FF
        x = (x | (x << 4)) & 0x0F0F_0F0F
        x = (x | (x << 2)) & 0x3333_3333
        x = (x | (x << 1)) & 0x5555_5555
        return x
    }
    /// Pins in this list plus any in its child lists (folder rollup count).
    var rollupPinCount: Int { livePins.count + liveChildLists.reduce(0) { $0 + $1.livePins.count } }
}

extension PinVM {
    var displayColor: Color { Color(hexString: list?.colorHex ?? ListVM.palette[0]) }
    /// Best thumbnail URL: a stored thumbnail/full file, else the remote source image.
    var thumbURL: URL? { thumbnailImages.first?.url ?? imageURL.flatMap { URL(string: $0) } }
}
#endif
