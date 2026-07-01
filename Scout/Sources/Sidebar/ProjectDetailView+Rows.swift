import SwiftUI
import ScoutKit
import UniformTypeIdentifiers

// Sidebar section & row view-builders (scripts, trash, uncategorized, lists, pins).
extension ProjectDetailView {
    /// Auto "Scripts" section (like Uncategorized/Trash): imported .fountain scripts.
    @ViewBuilder
    var scriptsSection: some View {
        let scripts = project.scripts.sorted { $0.sortOrder < $1.sortOrder }
        if !scripts.isEmpty {
            HStack(spacing: 6) {
                Button {
                    var tx = Transaction(animation: .none); tx.disablesAnimations = true
                    withTransaction(tx) { scriptsExpanded.toggle() }
                } label: {
                    Image(systemName: scriptsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: "doc.text").font(.caption).foregroundStyle(.secondary)
                Text("Scripts").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(scripts.count)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .listRowBackground(Color.clear)

            if scriptsExpanded {
                ForEach(scripts, id: \.id) { script in
                    scriptRow(script)
                }
            }
        }
    }

    @ViewBuilder
    func scriptRow(_ script: ScriptVM) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.plaintext").font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(script.name).font(.body).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
        .onTapGesture { onOpenScript?(script) }
        .contextMenu {
            Button { onOpenScript?(script) } label: { Label("Open Script", systemImage: "doc.text") }
            Divider()
            Button(role: .destructive) { deleteScript(script) } label: {
                Label("Delete Script", systemImage: "trash")
            }
        }
    }

    func deleteScript(_ script: ScriptVM) {
        Task { try? await ScoutStore.shared.deleteScript(id: script.id) }
    }

    /// Trash section — soft-deleted lists and photos, with Empty Trash. Auto-purged at 30 days.
    @ViewBuilder
    var trashSection: some View {
        let trashed = trashedPins
        let trashedListRows = trashedLists
        if !trashed.isEmpty || !trashedListRows.isEmpty {
            HStack(spacing: 6) {
                Button {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) { expandedTrash.toggle() }
            } label: {
                    Image(systemName: expandedTrash ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 28, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: "trash").font(.caption).foregroundStyle(.secondary)
                Text("Trash").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(trashed.count + trashedListRows.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button(role: .destructive) { emptyTrash() } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
            }
            .help("Items here are deleted automatically after 30 days")

            if expandedTrash {
                ForEach(trashedListRows, id: \.id) { list in
                    trashedListRow(list)
                }
                ForEach(trashed, id: \.id) { pin in
                    trashedPinRow(pin)
                }
            }
        }
    }

    /// A single trashed-photo row in the Trash section.
    @ViewBuilder
    func trashedPinRow(_ pin: PinVM) -> some View {
        PinRow(pin: pin, selection: selection, onTap: { _, _ in }, onDoubleTap: {})
            .padding(.leading, 24)
            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
            .opacity(0.6)
            .contextMenu {
                Button { restoreFromTrash(pin) } label: {
                    Label("Put Back", systemImage: "arrow.uturn.backward")
                }
                Divider()
                Button(role: .destructive) { purgePin(pin) } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
            }
    }

    /// A trashed list row — collapsible, shows photos inside when expanded. Same visual
    /// language as the live sidebar: chevron, list icon, name, count badge.
    @ViewBuilder
    func trashedListRow(_ list: ListVM) -> some View {
        let pins = list.pins.sorted { $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt }
        let n = photoCount(in: list)
        let isExpanded = expandedTrashListIDs.contains(list.id)

        // Header row
        HStack(spacing: 0) {
            // Chevron — only show when there are photos to expand into
            Button {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) {
                    if isExpanded { expandedTrashListIDs.remove(list.id) }
                    else { expandedTrashListIDs.insert(list.id) }
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(n > 0 ? Color.secondary : Color.clear)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(n == 0)

            Image(systemName: list.childLists.isEmpty ? "list.bullet" : "folder")
                .font(.caption).foregroundStyle(.secondary).frame(width: 14)
            Text(list.name).font(.body).foregroundStyle(.primary).padding(.leading, 6)
            Spacer()
            if n > 0 {
                Text("\(n)").font(.caption).foregroundStyle(.secondary).padding(.trailing, 4)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .opacity(0.6)
        .contextMenu {
            Button { restoreList(list) } label: {
                Label("Put Back", systemImage: "arrow.uturn.backward")
            }
            Divider()
            Button(role: .destructive) { purgeList(list) } label: {
                Label("Delete Permanently", systemImage: "trash")
            }
        }

        // Expanded photos — same PinRow as the live sidebar, indented one more level
        if isExpanded {
            ForEach(pins, id: \.id) { pin in
                PinRow(pin: pin, selection: selection, onTap: { _, _ in }, onDoubleTap: {})
                    .listRowInsets(EdgeInsets(top: 0, leading: 48, bottom: 0, trailing: 0))
                    .opacity(0.6)
                    .contextMenu {
                        Button { pin.deletedAt = nil; restoreList(list) } label: {
                            Label("Put Back", systemImage: "arrow.uturn.backward")
                        }
                        Divider()
                        Button(role: .destructive) { purgeList(list) } label: {
                            Label("Delete Permanently", systemImage: "trash")
                        }
                    }
            }
        }
    }

    /// The Uncategorized pseudo-list row + its loose photos. Behaves like a normal list:
    /// collapsible, reorderable among top-level rows, eye toggle. It can't be nested into a
    /// folder, always holds the project's loose photos, and is the default import target.
    @ViewBuilder
    func uncategorizedSection(_ proj: ProjectVM, itemID: String) -> some View {
        let searching = !trimmedSearch.isEmpty
        let isExpanded = searching || uncategorizedExpanded
        let photos = (searching ? loosePhotos.filter { nameMatches($0.name) } : loosePhotos)
            .filter { !flaggedOnly || $0.isFlagged }

        HStack(spacing: 6) {
            Button {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) { uncategorizedExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Drag handle: only this region starts a reorder drag (matches ListRow).
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 10)
                Text("Uncategorized").font(.body).foregroundStyle(.primary)
                Spacer()
                // Show the count that matches what's actually rendered below — i.e. respect the
                // "flagged only" filter, so the badge never reads 92 while the section is empty.
                if !photos.isEmpty {
                    Text("\(photos.count)").font(.caption).foregroundStyle(.secondary)
                } else if flaggedOnly && !loosePhotos.isEmpty {
                    // Filter is hiding everything here — show "0 of N" so it's obvious why.
                    Text("0 of \(loosePhotos.count)").font(.caption).foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .onDrag { beginListDrag("uncategorized") }

            Button {
                let pid = proj.id
                if currentModifierFlags().option {
                    setProjectVisibility(!uncategorizedVisible)
                } else if uncategorizedVisible {
                    hiddenUncategorizedProjectIDs.insert(pid)
                } else {
                    hiddenUncategorizedProjectIDs.remove(pid)
                }
            } label: {
                Image(systemName: uncategorizedVisible ? "eye.fill" : "eye")
                    .foregroundStyle(uncategorizedVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Show/hide uncategorized photos on the map and grid (⌥ toggles everything)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            searchFieldFocused = false
            onClearPin?()
            onFitToList?(loosePhotos.filter { $0.hasGPS })
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { handleUncategorizedDoubleTap() })
        .background { rowHeightReader(itemID) }
        .overlay { dropIndicator(for: itemID) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: itemID,
                    allowNest: false,
                    height: { rowHeights[itemID] ?? 36 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in performRowDrop(target: .uncategorized(proj), mode: mode, providers: providers) }
                ))

        if isExpanded {
            // The flag filter is hiding every loose photo here — say so plainly and offer a
            // one-click way out, right where the photos would otherwise be.
            if photos.isEmpty && flaggedOnly && !loosePhotos.isEmpty {
                Button { flaggedOnly = false } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flag.slash")
                        Text("\(loosePhotos.count) hidden by flag filter — Show all")
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 24).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
            }
            ForEach(photos) { pin in
                PinRow(
                    pin: pin,
                    selection: selection,
                    onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
                    onDoubleTap: { handleDoubleTap(pin.uuid) }
                )
                .padding(.leading, 24)
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
                .contextMenu { pinContextMenu(pin) }
                .onDrag { beginPhotoDrag("photo:\(pin.uuid.uuidString)") }
                .onDrop(of: [.text, .fileURL, .image], isTargeted: nil) { providers in
                    tryImportDrop(providers, into: nil) || loadDropPinToUncategorized(providers)
                }
            }
        }
    }

    /// Loads a drag payload and moves the dragged pin(s) into Uncategorized (loose photos).
    func loadDropPinToUncategorized(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                let uuids: [String]
                if dragID.hasPrefix("photos:") { uuids = dragID.dropFirst(7).split(separator: ",").map(String.init) }
                else if dragID.hasPrefix("photo:") { uuids = [String(dragID.dropFirst(6))] }
                else if dragID.hasPrefix("pin:") { uuids = [String(dragID.dropFirst(4))] }
                else { return }
                for pin in uuids.compactMap({ findPin(uuid: $0) }) { movePinToUncategorized(pin) }
            }
        }
        return true
    }

    /// One top-level sidebar row (extracted from the List ForEach to keep the body
    /// type-checkable). Dispatches to the loose-photo, list, or uncategorized row.
    @ViewBuilder
    func sidebarRow(_ item: SidebarItem) -> some View {
        switch item {
        case .photo(let pin):       topPhotoRow(pin, item: item)
        case .list(let list):       listSection(list, item: item)
        case .uncategorized(let p): uncategorizedSection(p, itemID: item.id)
        }
    }

    /// A loose (top-level) photo row.
    @ViewBuilder
    func topPhotoRow(_ pin: PinVM, item: SidebarItem) -> some View {
        PinRow(
            pin: pin,
            selection: selection,
            onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(pin.uuid) }
        )
        .contextMenu { pinContextMenu(pin) }
        .background { rowHeightReader(item.id) }
        .overlay { dropIndicator(for: item.id) }
        .onDrag { beginItemDrag(item) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: item.id,
                    allowNest: false,
                    height: { rowHeights[item.id] ?? 60 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in performRowDrop(target: .photo(pin), mode: mode, providers: providers) }
                ))
    }

    /// A list/folder header row, plus its expanded child lists and pins.
    @ViewBuilder
    func listSection(_ list: ListVM, item: SidebarItem) -> some View {
        // While searching, force lists open so matching photos are visible.
        let searching = !trimmedSearch.isEmpty
        let isExpanded = searching || expandedListIDs.contains(list.id)
        let isFolder = !list.childLists.isEmpty
        let isNested = list.parentList != nil
        ListRow(
            list: list,
            isExpanded: isExpanded,
            isFolder: isFolder,
            isNested: isNested,
            selection: selection,
            onToggleExpand: {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) {
                    if isExpanded { expandedListIDs.remove(list.id) }
                    else { expandedListIDs.insert(list.id) }
                }
            },
            onTap: { shift, option in handleTap(list.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(list.uuid) },
            activeListIDs: $activeListIDs,
            onFitToList: onFitToList,
            onRename: {
                renameListText = list.name
                renamingList = list
            },
            onToggleAllVisibility: { makeAllActive in
                setProjectVisibility(makeAllActive)
            },
            onEnable: { enableWithDescendants(list) },
            onMoveToTopLevel: { unnestList(list) },
            onDelete: { requestDeleteList(list) },
            dragProvider: { beginItemDrag(item) },
            sceneTypeEditID: $sceneTypeEditID,
            onOpenSceneLink: { onOpenScriptHighlight?($0) }
        )
        .background { rowHeightReader(item.id) }
        .overlay { dropIndicator(for: item.id) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: item.id,
                    allowNest: true,
                    height: { rowHeights[item.id] ?? 36 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in performRowDrop(target: .list(list), mode: mode, providers: providers) }
                ))

        if isExpanded {
            // Script scenes assigned to this list — pinned at the TOP of the list (above photos
            // and child lists). Click to jump to that spot in the script.
            let scenes = list.sceneLinks.sorted { $0.rangeStart < $1.rangeStart }
            ForEach(scenes, id: \.id) { scene in
                sceneRow(scene, color: Color(hexString: list.colorHex))
            }

            // Child lists (folders) shown before pins.
            let childLists = list.childLists
                .filter { $0.deletedAt == nil }
                .sorted {
                    $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
                }.filter { !searching || nameMatches($0.name) || $0.livePins.contains { nameMatches($0.name) } }
            ForEach(childLists, id: \.id) { child in
                childListRow(child, folder: list)
            }

            let pins = flaggedFirst(list.pins.filter { $0.deletedAt == nil && (!flaggedOnly || $0.isFlagged) })
                .filter { !searching || nameMatches(list.name) || nameMatches($0.name) }
            ForEach(Array(pins.enumerated()), id: \.element.id) { idx, pin in
                expandedPinRow(pin, in: list, indexBefore: idx > 0 ? pins[idx - 1] : nil)
            }
        }
    }

    /// A "scene" row inside an expanded list: the linked script excerpt; tap to open it.
    @ViewBuilder
    func sceneRow(_ scene: HighlightVM, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").font(.caption2).foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                if let h = scene.sceneHeading, !h.isEmpty {
                    Text(h).font(.caption.weight(.medium)).lineLimit(1)
                }
                Text(scene.excerpt.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .contentShape(Rectangle())
        .onTapGesture { onOpenScriptHighlight?(scene) }
        .contextMenu {
            Button { onOpenScriptHighlight?(scene) } label: { Label("Open in Script", systemImage: "doc.text") }
            Divider()
            Button(role: .destructive) { deleteSceneLink(scene) } label: {
                Label("Remove Scene Link", systemImage: "trash")
            }
        }
    }

    func deleteSceneLink(_ scene: HighlightVM) {
        Task { try? await ScoutStore.shared.deleteHighlight(id: scene.id) }
    }

    /// A pin row shown inside an expanded list, with reorder drop support.
    @ViewBuilder
    func expandedPinRow(_ pin: PinVM, in list: ListVM,
                                indexBefore beforeNeighbor: PinVM?) -> some View {
        PinRow(
            pin: pin,
            selection: selection,
            listColor: Color(hexString: list.colorHex),
            onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(pin.uuid) }
        )
        .padding(.leading, 24)
        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
        .contextMenu { pinContextMenu(pin) }
        .background { rowHeightReader(pin.id) }
        .overlay { dropIndicator(for: pin.id) }
        .onDrag { beginPhotoDrag("pin:\(pin.uuid.uuidString)") }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: pin.id,
                    allowNest: false,
                    height: { rowHeights[pin.id] ?? 60 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in
                        reorderPinDrop(providers, list: list, target: pin,
                                       beforeNeighbor: beforeNeighbor, mode: mode)
                    }
                ))
    }

    /// One child-list row inside a folder, with drag-to-reorder and its pin expansion.
    @ViewBuilder
    func childListRow(_ child: ListVM, folder: ListVM) -> some View {
        let childExpanded = expandedListIDs.contains(child.id)
        ListRow(
            list: child,
            isExpanded: childExpanded,
            isFolder: false,
            isNested: true,
            selection: selection,
            onToggleExpand: {
                var tx = Transaction(animation: .none); tx.disablesAnimations = true
                withTransaction(tx) {
                    if childExpanded { expandedListIDs.remove(child.id) }
                    else { expandedListIDs.insert(child.id) }
                }
            },
            onTap: { shift, option in handleTap(child.uuid, shift: shift, option: option) },
            onDoubleTap: { handleDoubleTap(child.uuid) },
            activeListIDs: $activeListIDs,
            onFitToList: onFitToList,
            onRename: {
                renameListText = child.name
                renamingList = child
            },
            onMoveToTopLevel: { unnestList(child) },
            onDelete: { requestDeleteList(child) },
            dragProvider: { beginListDrag("list:\(child.uuid.uuidString)") },
            sceneTypeEditID: $sceneTypeEditID,
            onOpenSceneLink: { onOpenScriptHighlight?($0) }
        )
        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 0))
        .padding(.leading, 18)
        // NOTE: deliberately NO rowHeightReader/GeometryReader here. A GeometryReader's
        // onAppear writes the `rowHeights` @State on every child mount, and each write
        // re-renders this whole view — so a folder with N children fired N extra body
        // passes on expand, making folders far slower to open than plain photo lists.
        // These rows are single-line and use allowNest:false (a plain before/after split
        // at the midpoint), so a constant height is exact enough for drag-reorder.
        .overlay { dropIndicator(for: child.id) }
        .onDrop(of: [.text, .fileURL, .image],
                delegate: SidebarRowDropDelegate(
                    targetID: child.id,
                    // Allow nesting so the middle zone is a "drop INTO this list" target (the
                    // row highlights) — needed so photos can be dropped straight into a list
                    // that lives inside a folder, not just reordered around it.
                    allowNest: true,
                    height: { 36 },
                    onTargetChange: { id, mode in setDropTarget(id, mode: mode) },
                    onExit: { id in clearDropTarget(ifOwnedBy: id) },
                    onPerform: { mode, providers in
                        performChildRowDrop(providers, folder: folder, target: child, mode: mode)
                    }
                ))

        if childExpanded {
            // Scene links pinned at the top of the child list too.
            let scenes = child.sceneLinks.sorted { $0.rangeStart < $1.rangeStart }
            ForEach(scenes, id: \.id) { scene in
                sceneRow(scene, color: Color(hexString: child.colorHex))
                    .padding(.leading, 18)
            }

            let childPins = flaggedFirst(child.pins.filter { $0.deletedAt == nil && (!flaggedOnly || $0.isFlagged) })
            ForEach(childPins) { pin in
                PinRow(
                    pin: pin,
                    selection: selection,
                    listColor: Color(hexString: child.colorHex),
                    onTap: { shift, option in handleTap(pin.uuid, shift: shift, option: option) },
                    onDoubleTap: { handleDoubleTap(pin.uuid) }
                )
                .padding(.leading, 42)
                .listRowInsets(EdgeInsets(top: 0, leading: 42, bottom: 0, trailing: 0))
                .contextMenu { pinContextMenu(pin) }
            }
        }
    }

    /// Right-click menu for a sidebar pin row — uses the SHARED pin menu (origin .sidebar), so
    /// it's identical to the grid/map menus aside from the sidebar-only "Reveal in Photo Grid"
    /// and "Reveal on Map" options.
    @ViewBuilder func pinContextMenu(_ pin: PinVM) -> some View {
        pinContextMenuItems(.sidebar, sidebarPinMenuActions(pin))
    }

    func sidebarPinMenuActions(_ pin: PinVM) -> PinMenuActions {
        let multi = isInMultiSelection(pin.uuid)
        var revealFinder: (() -> Void)? = nil
        #if os(macOS)
        if let path = pin.originalFilePath {
            revealFinder = { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
        }
        #endif
        return PinMenuActions(
            isFlagged: pin.isFlagged,
            toggleFlag: { toggleFlag(pin) },
            revealInFinder: revealFinder,
            revealInList: nil,
            revealInGrid: onRevealInGrid.map { f in { f(pin.uuid) } },
            revealOnMap: onRevealOnMap.map { f in { f(pin.uuid) } },
            delete: { if multi { deleteSelectedItems() } else { deletePin(pin) } }
        )
    }
}
