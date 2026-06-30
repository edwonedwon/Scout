import SwiftUI
import ScoutKit

// MARK: - List row (expand in place to see pins)

struct ListRow: View {
    let list: ListVM
    let isExpanded: Bool
    var isFolder: Bool = false
    var isNested: Bool = false
    @ObservedObject var selection: SelectionStore
    let onToggleExpand: () -> Void
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil
    @Binding var activeListIDs: Set<String>
    var onFitToList: (([PinVM]) -> Void)?
    var onRename: (() -> Void)? = nil
    /// Called when the user Option+clicks the eye. `true` = show all, `false` = hide all.
    var onToggleAllVisibility: ((Bool) -> Void)? = nil
    /// Called instead of the default `activeListIDs.insert` when turning a list on —
    /// lets the parent cascade-enable folder children. Defaults to simple insert.
    var onEnable: (() -> Void)? = nil
    var onMoveToTopLevel: (() -> Void)? = nil
    /// Called when the user chooses "Delete List". The parent shows a confirm dialog and
    /// moves the list to the Trash — ListRow never deletes directly.
    var onDelete: (() -> Void)? = nil
    /// Supply a drag provider to make the name area a drag handle. Buttons are
    /// excluded so accidental drag on chevron/eye never triggers a reorder.
    var dragProvider: (() -> NSItemProvider)? = nil
    /// Which list's scene-type popover is open (shared across rows); the popover anchors to the
    /// row whose `list.uuid` matches. Set by clicking the chip or the panel's "e" shortcut.
    var sceneTypeEditID: Binding<UUID?>? = nil
    /// Tapping the header's scene-count badge opens the script at that scene link.
    var onOpenSceneLink: ((HighlightVM) -> Void)? = nil

    private var isActive: Bool { activeListIDs.contains(list.id) }
    private var isSelected: Bool { selection.contains(list.uuid) }
    private var listColor: Color { Color(hexString: list.colorHex) }

    /// Live (non-trashed) photo count for a list, including its live child lists (recursively).
    static func liveCount(_ list: ListVM) -> Int {
        list.pins.filter { $0.deletedAt == nil }.count
            + list.childLists.filter { $0.deletedAt == nil }.reduce(0) { $0 + liveCount($1) }
    }

    /// True if any live photo in this list (or a live child list) is flagged — so the header can
    /// show a flag, signalling a filming location has already been chosen for the list.
    static func hasFlagged(_ list: ListVM) -> Bool {
        list.pins.contains { $0.deletedAt == nil && $0.isFlagged }
            || list.childLists.filter { $0.deletedAt == nil }.contains { hasFlagged($0) }
    }

    /// Scene-type chip: a fixed-size dark-grey rectangle with a light-grey border. Click (or press
    /// "e" with the list selected) opens the None / INT / EXT / INT/EXT chooser as a popover
    /// anchored here. "INT/EXT" is stacked (INT over EXT) so the chip stays compact and its width
    /// never changes with the choice; unset shows a dimmed "INT/EXT" placeholder. It's a plain
    /// Button (not a Menu) because `.menuStyle(.borderlessButton)` ignored the label's font/frame/
    /// border — so the stacked text and outline weren't rendering.
    private var sceneTypeMenu: some View {
        Button {
            sceneTypeEditID?.wrappedValue = list.uuid
        } label: {
            sceneTypeLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: sceneTypePopoverBinding, arrowEdge: .top) {
            SceneTypePickerSheet(
                current: list.sceneType,
                onPick: { newType in
                    list.sceneType = newType
                    sceneTypeEditID?.wrappedValue = nil
                },
                onDismiss: { sceneTypeEditID?.wrappedValue = nil }
            )
        }
    }

    /// True when this row is the scene-type edit target (drives its popover).
    private var sceneTypePopoverBinding: Binding<Bool> {
        Binding(
            get: { sceneTypeEditID?.wrappedValue == list.uuid },
            set: { if !$0 { sceneTypeEditID?.wrappedValue = nil } }
        )
    }

    @ViewBuilder
    private var sceneTypeLabel: some View {
        let isStacked = (list.sceneType == nil || list.sceneType == "INT/EXT")
        // Placeholder (unset) is dimmer than a set value, but still visible in dark mode.
        let textColor = list.sceneType == nil ? Color(white: 0.6) : Color(white: 0.95)
        Group {
            if isStacked {
                // INT over EXT, each at ~half height so the pair stacks within a single line.
                VStack(spacing: -2) {
                    Text("INT")
                    Text("EXT")
                }
                .font(.system(size: 7, weight: .bold))
            } else {
                Text(list.sceneType ?? "")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .lineLimit(1)
        .foregroundStyle(textColor)
        .frame(width: 34, height: 22)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.32)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(white: 0.72), lineWidth: 1))
    }

    var body: some View {
        HStack(spacing: 6) {
            // Chevron and eye are Buttons so clicking them toggles expand/visibility
            // without selecting the row.
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Color dot (or folder icon).
            if isFolder {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            } else {
                Circle()
                    .fill(listColor)
                    .frame(width: 10, height: 10)
            }

            // Screenplay scene type (INT / EXT / INT/EXT), pickable via menu. Sits between the
            // dot and the title. Kept out of the drag handle so a click opens the menu rather
            // than starting a reorder drag.
            sceneTypeMenu
                .padding(.horizontal, 5)

            // Drag handle: the list name initiates a reorder drag.
            Text(list.name)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .modifier(OptionalDrag(provider: dragProvider))

            Spacer()

            // Order (left→right): flag, scene badge, count, eye.
            // A flag here means at least one photo in the list is flagged — i.e. a filming
            // location has already been picked for this list.
            if ListRow.hasFlagged(list) {
                Image(systemName: "flag.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            // Scene indicator: this list has script scene(s) assigned. Click → open the script at
            // the first one (same as clicking the list's scene row).
            if !list.sceneLinks.isEmpty {
                Button {
                    if let first = list.sceneLinks.sorted(by: { $0.rangeStart < $1.rangeStart }).first {
                        onOpenSceneLink?(first)
                    }
                } label: {
                    HStack(spacing: 1) {
                        Image(systemName: "text.quote")
                        Text("\(list.sceneLinks.count)")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            // Count only LIVE photos (and live child lists), recursively — trashed photos
            // stay in `list.pins` (soft-delete just sets deletedAt), so counting them made
            // the header number exceed what's actually shown in the sidebar/grid/map.
            let pinCount = ListRow.liveCount(list)
            if pinCount > 0 {
                Text("\(pinCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                let optionHeld = currentModifierFlags().option
                if optionHeld, let toggle = onToggleAllVisibility {
                    // Option+click: show all when this one is hidden, hide all when visible.
                    toggle(!isActive)
                } else {
                    if isActive { activeListIDs.remove(list.id) }
                    else if let enable = onEnable { enable() }
                    else { activeListIDs.insert(list.id) }
                }
            } label: {
                Image(systemName: isActive ? "eye.fill" : "eye")
                    .foregroundStyle(isActive ? listColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(onToggleAllVisibility != nil ? "Click to toggle · Option+click to toggle all" : "")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .onTapGesture { { let m = currentModifierFlags(); onTap?(m.shift, m.option) }() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        .contextMenu {
            Button { onRename?() } label: {
                Label("Rename List", systemImage: "pencil")
            }
            if let onFitToList {
                Button {
                    let allPins = list.pins.filter { $0.hasGPS && $0.deletedAt == nil }
                        + list.childLists.flatMap { $0.pins.filter { $0.hasGPS && $0.deletedAt == nil } }
                    onFitToList(allPins)
                } label: {
                    Label("Fit Map to List", systemImage: "mappin.and.ellipse")
                }
            }
            // Unnest a folder child back to the top level. (Nesting is drag-only.)
            if isNested {
                Divider()
                Button { onMoveToTopLevel?() } label: {
                    Label("Move to Top Level", systemImage: "arrow.up.to.line")
                }
            }
            Divider()
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}

/// Applies `.onDrag` only when a provider is supplied, letting call sites restrict
/// dragging to a specific sub-region while leaving button areas drag-free.
struct OptionalDrag: ViewModifier {
    let provider: (() -> NSItemProvider)?
    func body(content: Content) -> some View {
        if let provider {
            content.onDrag(provider)
        } else {
            content
        }
    }
}

// MARK: - Pin row (shared by photos and list pins)

struct PinRow: View {
    let pin: PinVM
    @ObservedObject var selection: SelectionStore
    var listColor: Color? = nil
    var onTap: ((Bool, Bool) -> Void)? = nil
    var onDoubleTap: (() -> Void)? = nil

    private var isSelected: Bool { selection.contains(pin.uuid) }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 3) {
                Text(pin.name)
                    .font(.body)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !pin.hasGPS {
                    Label("No GPS", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Flagged (favorite filming location) marker.
            if pin.isFlagged {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.trailing, 4)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        // Single click selects (instant); double click zooms. Manual handling — no native
        // List selection — so selecting thousands is an O(1) set write with no per-row work.
        .onTapGesture { { let m = currentModifierFlags(); onTap?(m.shift, m.option) }() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleTap?() })
        // NOTE: no .contextMenu here — each pin row attaches the shared `pinContextMenu(pin)`
        // from ProjectDetailView (which has access to flag/delete). An inner menu here would
        // shadow it.
    }

    @ViewBuilder
    private var thumbnail: some View {
        let url: URL? = pin.thumbnailImages.first?.url
            ?? pin.photoFiles.first.map { PinPhotoStore.fileURL($0) }
            ?? pin.imageURL.flatMap { URL(string: $0) }
        if let url {
            // GooglePhotoImage uses PhotoLoader's shared NSCache — thumbnails are decoded
            // once and reused on scroll, unlike AsyncImage which has no cache.
            GooglePhotoImage(url: url, rotationQuarterTurns: pin.rotationQuarterTurns) {
                Color.secondary.opacity(0.2)
            }
            .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mappin").foregroundStyle(.secondary))
        }
    }
}

// MARK: - OutlineGroup children helper

extension ListVM {
    var sortedChildren: [ListVM]? {
        let children = childLists.sorted { $0.sortOrder < $1.sortOrder }
        return children.isEmpty ? nil : children
    }
}
