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
}

extension ListVM {
    var iosSortedChildren: [ListVM] { liveChildLists.sorted { $0.panelOrder < $1.panelOrder } }
    var sortedPins: [PinVM] { livePins.sorted { $0.sortOrder < $1.sortOrder } }
    var isFolder: Bool { !liveChildLists.isEmpty }
    /// Pins in this list plus any in its child lists (folder rollup count).
    var rollupPinCount: Int { livePins.count + liveChildLists.reduce(0) { $0 + $1.livePins.count } }
}

extension PinVM {
    var displayColor: Color { Color(hexString: list?.colorHex ?? ListVM.palette[0]) }
    /// Best thumbnail URL: a stored thumbnail/full file, else the remote source image.
    var thumbURL: URL? { thumbnailImages.first?.url ?? imageURL.flatMap { URL(string: $0) } }
}
#endif
