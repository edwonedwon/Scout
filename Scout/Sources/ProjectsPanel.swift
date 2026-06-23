import SwiftUI
import SwiftData
import ScoutKit
import CoreLocation
import UniformTypeIdentifiers

// MARK: - Finder drag helpers

let imageExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","webp","gif","bmp","raw","arw","cr2","nef","dng"]

/// Extracts file URLs from NSItemProvider items produced by Finder drags.
/// Uses NSURL (not loadItem) because that's what Finder actually vends.
/// Returns only image files by extension.
func loadImageURLs(from providers: [NSItemProvider]) async -> [URL] {
    await withTaskGroup(of: URL?.self) { group in
        for provider in providers {
            group.addTask {
                // Try NSURL first — this is what Finder drag-and-drop provides.
                if provider.canLoadObject(ofClass: NSURL.self) {
                    return await withCheckedContinuation { cont in
                        _ = provider.loadObject(ofClass: NSURL.self) { reading, _ in
                            if let url = reading as? URL,
                               imageExtensions.contains(url.pathExtension.lowercased()) {
                                cont.resume(returning: url)
                            } else {
                                cont.resume(returning: nil)
                            }
                        }
                    }
                }
                // Fallback: raw loadItem for public.file-url
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    return await withCheckedContinuation { cont in
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            let url: URL?
                            if let data = item as? Data {
                                url = URL(dataRepresentation: data, relativeTo: nil)
                            } else {
                                url = item as? URL
                            }
                            if let url, imageExtensions.contains(url.pathExtension.lowercased()) {
                                cont.resume(returning: url)
                            } else {
                                cont.resume(returning: nil)
                            }
                        }
                    }
                }
                return nil
            }
        }
        var urls: [URL] = []
        for await url in group { if let url { urls.append(url) } }
        return urls
    }
}

// MARK: - Shared drag state for moving/reordering saved pins
//
// Rather than serialize a pin identity through the pasteboard (which proved
// unreliable across separate ListCard views), we hold the actual dragged pin
// in a shared object. The drop reads the exact in-memory reference — no
// serialization, no UUID lookup, works identically within and across lists.

final class PinDragState: ObservableObject {
    var draggedPin: PinnedLocationData?
    var draggedList: LocationListData?
}

// MARK: - Projects panel

struct ProjectsPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectData.createdAt) private var projects: [ProjectData]

    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onSelectPin: ((PinnedLocationData) -> Void)? = nil

    @State private var showAddProject = false
    @State private var newProjectName = ""
    @State private var addingListTo: ProjectData?
    @State private var newListName = ""
    @AppStorage("sidebar.showPinPhotos") private var showPinPhotos = false
    @StateObject private var dragState = PinDragState()

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider()

            if projects.isEmpty {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder.badge.plus",
                    description: Text("Create a project to organize your scouting locations.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(projects) { project in
                            projectSection(project)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .sheet(isPresented: $showAddProject) {
            NameEntrySheet(
                title: "New Project",
                placeholder: "Project name",
                text: $newProjectName,
                onDismiss: { showAddProject = false }
            ) { name in
                let p = ProjectData(name: name)
                modelContext.insert(p)
                showAddProject = false
            }
        }
        .sheet(item: $addingListTo) { project in
            NameEntrySheet(
                title: "New List in \(project.name)",
                placeholder: "List name",
                text: $newListName,
                onDismiss: { addingListTo = nil }
            ) { name in
                let colorHex = LocationListData.palette[project.lists.count % LocationListData.palette.count]
                let list = LocationListData(name: name, colorHex: colorHex)
                let topCount = project.lists.filter { $0.parentList == nil }.count
                list.sortOrder = topCount
                modelContext.insert(list)
                list.project = project   // inverse adds it to project.lists
                addingListTo = nil
            }
        }
    }

    // MARK: - Project section

    private func projectSection(_ project: ProjectData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            projectHeader(project)

            ImportedPhotosList(project: project, showPhoto: showPinPhotos, onSelectPin: onSelectPin ?? { _ in })

            let topLevel = ordered(project.lists.filter { $0.parentList == nil })
            ForEach(topLevel) { list in
                ListCard(list: list, activeListIDs: $activeListIDs, modelContext: modelContext,
                         showPinPhotos: showPinPhotos, dragState: dragState,
                         onFitToList: onFitToList, onSelectPin: onSelectPin)
            }

            // Drop a list here to move it to the end of the top level
            Color.clear
                .frame(height: 8)
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    guard let dragged = dragState.draggedList else { return false }
                    moveToTopLevel(dragged, in: project)
                    dragState.draggedList = nil
                    return true
                }

            HStack(spacing: 12) {
                Button {
                    newListName = ""
                    addingListTo = project
                } label: {
                    Label("Add List", systemImage: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button {
                    addDummyPhoto(to: project)
                } label: {
                    Label("Import Photo", systemImage: "photo.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    private func addDummyPhoto(to project: ProjectData) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let results = await PhotoImportService.importPhotos(from: urls, into: nil)
            for result in results {
                modelContext.insert(result.pin)
                project.importedPhotos.append(result.pin)
            }
            try? modelContext.save()
        }
    }

    private func projectHeader(_ project: ProjectData) -> some View {
        ProjectHeader(project: project, activeListIDs: $activeListIDs, modelContext: modelContext)
    }

    private var panelHeader: some View {
        HStack {
            Text("Projects")
                .font(.headline)
            Spacer()
            // Photos toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showPinPhotos.toggle() }
            } label: {
                Image(systemName: showPinPhotos ? "photo.fill" : "photo")
                    .font(.body)
                    .foregroundStyle(showPinPhotos ? .blue : .secondary)
            }
            .buttonStyle(.plain)
            .help(showPinPhotos ? "Hide photos" : "Show photos")

            Button { showAddProject = true } label: {
                Image(systemName: "plus").font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        #if os(macOS)
        .padding(.top, 28)
        #endif
    }
}

// MARK: - Project header (own view for @State drop-highlight)

private struct ProjectHeader: View {
    let project: ProjectData
    @Binding var activeListIDs: Set<PersistentIdentifier>
    let modelContext: ModelContext

    @State private var isImageDropTarget = false
    @State private var importStatusMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(project.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isImageDropTarget ? .blue : .primary)
                Spacer()
                if let msg = importStatusMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Button {
                    for l in project.lists where activeListIDs.contains(l.persistentModelID) {
                        activeListIDs.remove(l.persistentModelID)
                    }
                    modelContext.delete(project)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isImageDropTarget ? Color.blue.opacity(0.08) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(isImageDropTarget ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1.5)
                    )
            )
            .animation(.easeInOut(duration: 0.12), value: isImageDropTarget)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isImageDropTarget) { providers in
            Task {
                let urls = await loadImageURLs(from: providers)
                guard !urls.isEmpty else { return }
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                let listName = "Imported \(fmt.string(from: Date()))"
                let colorHex = LocationListData.palette[project.lists.count % LocationListData.palette.count]
                let newList = LocationListData(name: listName, colorHex: colorHex)
                newList.sortOrder = project.lists.filter { $0.parentList == nil }.count
                modelContext.insert(newList)
                newList.project = project
                let results = await PhotoImportService.importPhotos(from: urls, into: newList)
                var withGPS = 0, withoutGPS = 0
                for r in results {
                    modelContext.insert(r.pin)
                    r.pin.list = newList
                    if r.hadGPS { withGPS += 1 } else { withoutGPS += 1 }
                }
                if results.isEmpty { return }
                var parts: [String] = []
                if withGPS > 0 { parts.append("\(withGPS) on map") }
                if withoutGPS > 0 { parts.append("\(withoutGPS) no GPS") }
                withAnimation { importStatusMessage = parts.joined(separator: ", ") }
                try? modelContext.save()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    withAnimation { importStatusMessage = nil }
                }
            }
            return true
        }
    }
}

// MARK: - List card

private struct ListCard: View {
    let list: LocationListData
    @Binding var activeListIDs: Set<PersistentIdentifier>
    let modelContext: ModelContext
    var showPinPhotos: Bool = false
    let dragState: PinDragState
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onSelectPin: ((PinnedLocationData) -> Void)? = nil

    @State private var isTargeted = false         // ScoutLocation drop highlight
    @State private var isPinDropTarget = false    // PinnedPin / nest drop highlight
    @State private var isPhotoDropTarget = false  // Finder photo drag highlight
    @State private var isReorderTarget = false    // list-reorder gap highlight
    @State private var insertBeforeID: PersistentIdentifier? = nil
    @State private var isExpanded = true
    @State private var isEditingName = false
    @State private var editingName = ""
    @FocusState private var nameFocused: Bool
    @State private var showImportPicker = false
    @State private var importStatusMessage: String? = nil

    private var isActive: Bool { activeListIDs.contains(list.persistentModelID) }
    private var listColor: Color { Color(hexString: list.colorHex) }
    private var isHighlighted: Bool { isTargeted || isPinDropTarget || isPhotoDropTarget }

    private var sortedChildren: [LocationListData] { ordered(list.childLists) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            reorderZone   // drop a list here to place it before this one
            card
            if let msg = importStatusMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            if isExpanded, !sortedChildren.isEmpty {
                childListsView
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            Task {
                let results = await PhotoImportService.importPhotos(from: urls, into: list)
                var withGPS = 0, withoutGPS = 0
                for r in results {
                    modelContext.insert(r.pin)
                    r.pin.list = list
                    if r.hadGPS { withGPS += 1 } else { withoutGPS += 1 }
                }
                if results.isEmpty { return }
                var parts: [String] = []
                if withGPS > 0 { parts.append("\(withGPS) placed on map") }
                if withoutGPS > 0 { parts.append("\(withoutGPS) without GPS (hidden from map)") }
                importStatusMessage = parts.joined(separator: ", ")
                try? modelContext.save()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    importStatusMessage = nil
                }
            }
        }
    }

    /// Thin gap above the card that accepts a dragged list to reorder it before this one.
    private var reorderZone: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(isReorderTarget ? listColor : Color.clear)
            .frame(height: isReorderTarget ? 6 : 14)
            .onDrop(of: [.text], isTargeted: $isReorderTarget) { _ in
                guard let dragged = dragState.draggedList else { return false }
                reorderListBefore(dragged, target: list)
                dragState.draggedList = nil
                return true
            }
    }

    @ViewBuilder
    private var childListsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sortedChildren) { child in
                ListCard(list: child, activeListIDs: $activeListIDs, modelContext: modelContext,
                         showPinPhotos: showPinPhotos, dragState: dragState,
                         onFitToList: onFitToList, onSelectPin: onSelectPin)
            }
            // Drop a list here to append it at the end of this sub-level
            Color.clear
                .frame(height: 8)
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    guard let dragged = dragState.draggedList else { return false }
                    nestList(dragged, into: list)
                    dragState.draggedList = nil
                    return true
                }
        }
        .padding(.leading, 16)
        .overlay(alignment: .leading) {
            // Hierarchy guide line
            listColor.opacity(0.25).frame(width: 1.5).padding(.vertical, 2)
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            cardHeader
            if isExpanded, !list.pins.isEmpty {
                Divider()
                pinnedLocations
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isHighlighted ? listColor : Color(nsColor: .separatorColor).opacity(0.6),
                    lineWidth: isHighlighted ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isHighlighted ? 0.12 : 0.04), radius: isHighlighted ? 6 : 2, y: 1)
        .animation(.easeInOut(duration: 0.15), value: isHighlighted)
        // Finder photo drop — must come BEFORE dropDestination so macOS doesn't
        // let the ScoutLocation handler shadow it for non-matching content types.
        .onDrop(of: [.fileURL, .image], isTargeted: $isPhotoDropTarget) { providers in
            Task {
                let urls = await loadImageURLs(from: providers)
                guard !urls.isEmpty else { return }
                let results = await PhotoImportService.importPhotos(from: urls, into: list)
                var withGPS = 0, withoutGPS = 0
                for r in results {
                    modelContext.insert(r.pin)
                    r.pin.list = list
                    if r.hadGPS { withGPS += 1 } else { withoutGPS += 1 }
                }
                if results.isEmpty { return }
                var parts: [String] = []
                if withGPS > 0 { parts.append("\(withGPS) placed on map") }
                if withoutGPS > 0 { parts.append("\(withoutGPS) without GPS") }
                importStatusMessage = parts.joined(separator: ", ")
                try? modelContext.save()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { importStatusMessage = nil }
            }
            return true
        }
        // Drop search results onto the list card
        .dropDestination(for: ScoutLocation.self) { items, _ in
            for loc in items {
                let pin = PinnedLocationData(from: loc, sortOrder: list.pins.count)
                modelContext.insert(pin)
                pin.list = list
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button { beginEditing() } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button { showImportPicker = true } label: {
                Label("Import Photos…", systemImage: "square.and.arrow.down")
            }
            if list.parentList != nil {
                Button {
                    if let project = list.project { moveToTopLevel(list, in: project) }
                } label: {
                    Label("Move to Top Level", systemImage: "arrow.up.left")
                }
            }
            Button(role: .destructive) {
                activeListIDs.remove(list.persistentModelID)
                modelContext.delete(list)
            } label: {
                Label("Delete List", systemImage: "trash")
            }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            // Drag handle for reordering / nesting the list itself
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .onDrag {
                    dragState.draggedList = list
                    return NSItemProvider(object: "list:\(list.name)" as NSString)
                }

            Button {
                withAnimation(.spring(duration: 0.2)) {
                    if isActive { activeListIDs.remove(list.persistentModelID) }
                    else { activeListIDs.insert(list.persistentModelID) }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(isActive ? listColor : listColor.opacity(0.15))
                        .frame(width: 14, height: 14)
                    Circle()
                        .strokeBorder(listColor, lineWidth: isActive ? 0 : 1.5)
                        .frame(width: 14, height: 14)
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)

            if isEditingName {
                TextField("List name", text: $editingName)
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { isEditingName = false }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                    .onDisappear { commitName() }
            } else {
                Text(list.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { beginEditing() }
                    .onTapGesture(count: 1) {
                        guard !list.pins.isEmpty else { return }
                        onFitToList?(list.pins)
                    }
            }

            Spacer()

            Text("\(list.pins.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(list.pins.isEmpty && sortedChildren.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isEditingName
                ? listColor.opacity(0.12)
                : isHighlighted ? listColor.opacity(0.08) : Color.clear
        )
        .overlay(alignment: .bottom) {
            if isEditingName { listColor.frame(height: 1.5) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditingName else { return }
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        }
        // Drop onto the list title: a pin moves into this list; a list nests inside it.
        .onDrop(of: [.text], isTargeted: $isPinDropTarget) { _ in
            if let dragged = dragState.draggedPin {
                if dragged.list?.persistentModelID != list.persistentModelID {
                    movePin(dragged, toList: list)
                } else {
                    appendPin(dragged, in: sortedPins())
                }
                dragState.draggedPin = nil
                return true
            }
            if let draggedList = dragState.draggedList {
                let ok = nestList(draggedList, into: list)
                dragState.draggedList = nil
                return ok
            }
            return false
        }
    }

    private func beginEditing() {
        editingName = list.name
        isEditingName = true
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitName() {
        let trimmed = editingName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { list.name = trimmed }
        isEditingName = false
    }

    // MARK: - Pinned locations (with drag/drop reorder)

    private var pinnedLocations: some View {
        let sorted = sortedPins()
        return LazyVStack(spacing: 0) {
            ForEach(sorted) { pin in
                pinRow(pin, in: sorted)
            }

            // Drop zone at the bottom of the list (append after last pin)
            Color.clear
                .frame(height: 8)
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    guard let pin = dragState.draggedPin else { return false }
                    if pin.list?.persistentModelID == list.persistentModelID {
                        appendPin(pin, in: sorted)
                    } else {
                        movePin(pin, toList: list)
                    }
                    dragState.draggedPin = nil
                    return true
                }
        }
    }

    @ViewBuilder
    private func pinRow(_ pin: PinnedLocationData, in sorted: [PinnedLocationData]) -> some View {
        let isInsertTarget = insertBeforeID == pin.persistentModelID
        VStack(spacing: 0) {
            // Insert indicator
            if isInsertTarget {
                listColor.frame(height: 2).padding(.horizontal, 10)
            }

            HStack(spacing: 8) {
                // Drag handle
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)

                // Same row view as the sidebar search results.
                LocationRow(location: pin.asScoutLocation(), showsPhotos: showPinPhotos)

                if !pin.hasGPS {
                    Image(systemName: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("No GPS — not shown on map")
                }
            }
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .onTapGesture { onSelectPin?(pin) }
            .onDrag {
                dragState.draggedPin = pin
                return NSItemProvider(object: pin.uuid.uuidString as NSString)
            }
            .onDrop(of: [.text], isTargeted: Binding(
                get: { insertBeforeID == pin.persistentModelID },
                set: { targeted in
                    if targeted { insertBeforeID = pin.persistentModelID }
                    else if insertBeforeID == pin.persistentModelID { insertBeforeID = nil }
                }
            )) { _ in
                guard let dragged = dragState.draggedPin else { return false }
                insertBeforeID = nil
                if dragged.list?.persistentModelID == list.persistentModelID {
                    reorder(pin: dragged, before: pin, in: sorted)
                } else {
                    movePin(dragged, toList: list, before: pin, in: sorted)
                }
                dragState.draggedPin = nil
                return true
            }
            .contextMenu {
                Button(role: .destructive) {
                    modelContext.delete(pin)
                } label: {
                    Label("Remove from List", systemImage: "minus.circle")
                }
            }

            if pin.persistentModelID != sorted.last?.persistentModelID {
                Divider().padding(.leading, 34)
            }
        }
    }

    // MARK: - Sort + reorder helpers

    private func sortedPins() -> [PinnedLocationData] { ordered(list.pins) }

    private func reorder(pin dragged: PinnedLocationData, before target: PinnedLocationData, in sorted: [PinnedLocationData]) {
        guard dragged.persistentModelID != target.persistentModelID else { return }
        placeInOrder(dragged, before: target, among: sorted)
    }

    private func appendPin(_ dragged: PinnedLocationData, in sorted: [PinnedLocationData]) {
        placeInOrder(dragged, before: nil, among: sorted)
    }

    /// Move `pin` into `target` (the inverse relationship pulls it out of its old list),
    /// landing before `insertBefore` or at the end.
    private func movePin(_ pin: PinnedLocationData, toList target: LocationListData,
                         before insertBefore: PinnedLocationData? = nil,
                         in sorted: [PinnedLocationData] = []) {
        pin.list = target
        placeInOrder(pin, before: insertBefore, among: ordered(target.pins))
    }

    // MARK: - List move / nest helpers

    /// True if `maybeAncestor` is `node` or any of its ancestors — used to block cycles.
    private func isAncestor(_ maybeAncestor: LocationListData, of node: LocationListData) -> Bool {
        var cursor: LocationListData? = node
        while let c = cursor {
            if c.persistentModelID == maybeAncestor.persistentModelID { return true }
            cursor = c.parentList
        }
        return false
    }

    /// Nest `dragged` inside `target` at the end of its children.
    @discardableResult
    private func nestList(_ dragged: LocationListData, into target: LocationListData) -> Bool {
        guard dragged.persistentModelID != target.persistentModelID,
              !isAncestor(dragged, of: target) else { return false }
        dragged.parentList = target           // inverse maintains childLists arrays
        dragged.project = target.project
        placeInOrder(dragged, before: nil, among: ordered(target.childLists))
        return true
    }

    /// Place `dragged` immediately before `target`, as a sibling at target's level.
    private func reorderListBefore(_ dragged: LocationListData, target: LocationListData) {
        guard dragged.persistentModelID != target.persistentModelID,
              !isAncestor(dragged, of: target) else { return }
        dragged.parentList = target.parentList
        dragged.project = target.project
        let level = target.parentList?.childLists
            ?? target.project?.lists.filter { $0.parentList == nil } ?? []
        placeInOrder(dragged, before: target, among: ordered(level))
    }
}

// MARK: - Name entry sheet

private struct NameEntrySheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onDismiss: () -> Void
    let onCreate: (String) -> Void

    private var trimmed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 20) {
            Text(title).font(.headline)

            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !trimmed.isEmpty { onCreate(trimmed) } }

            HStack {
                Button("Cancel", action: onDismiss).buttonStyle(.bordered)
                Button("Create") { onCreate(trimmed) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

// MARK: - Drag reordering

/// SwiftData models carrying a manual `sortOrder` that can be reordered by drag/drop.
protocol Reorderable: AnyObject {
    var sortOrder: Int { get set }
    var persistentModelID: PersistentIdentifier { get }
}
extension PinnedLocationData: Reorderable {}
extension LocationListData: Reorderable {}

/// The one routine behind every drag reorder/move/nest: rebuild `siblings` with `moved`
/// placed just before `target` (appended when `target` is nil or absent), dropping any
/// existing copy of `moved`, then renumber `sortOrder` to 0..<n.
private func placeInOrder<T: Reorderable>(_ moved: T, before target: T?, among siblings: [T]) {
    var arr = siblings.filter { $0.persistentModelID != moved.persistentModelID }
    if let target, let idx = arr.firstIndex(where: { $0.persistentModelID == target.persistentModelID }) {
        arr.insert(moved, at: idx)
    } else {
        arr.append(moved)
    }
    for (i, x) in arr.enumerated() { x.sortOrder = i }
}

/// Detach `dragged` from any parent and append it to the project's top level.
/// Free function so both the project section and a list's context menu can call it.
private func moveToTopLevel(_ dragged: LocationListData, in project: ProjectData) {
    dragged.parentList = nil
    dragged.project = project
    placeInOrder(dragged, before: nil, among: ordered(project.lists.filter { $0.parentList == nil }))
}

private func ordered(_ pins: [PinnedLocationData]) -> [PinnedLocationData] {
    pins.sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.createdAt < $1.createdAt }
}
private func ordered(_ lists: [LocationListData]) -> [LocationListData] {
    lists.sorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.createdAt < $1.createdAt }
}

// MARK: - Imported photo row

private struct ImportedPhotosList: View {
    let project: ProjectData
    let showPhoto: Bool
    let onSelectPin: (PinnedLocationData) -> Void

    var body: some View {
        let sorted = project.importedPhotos.sorted { $0.sortOrder < $1.sortOrder }
        ForEach(sorted) { pin in
            ImportedPhotoRow(pin: pin, onSelectPin: onSelectPin, showPhoto: showPhoto)
        }
    }
}

private struct ImportedPhotoRow: View {
    let pin: PinnedLocationData
    let onSelectPin: (PinnedLocationData) -> Void
    let showPhoto: Bool
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            onSelectPin(pin)
        } label: {
            HStack(spacing: 6) {
                if let filename = pin.photoFiles.first {
                    let url = PinPhotoStore.fileURL(filename)
                    AsyncImage(url: url) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.2)
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(pin.name)
                        .font(.caption)
                        .lineLimit(1)
                    if !pin.hasGPS {
                        Label("No GPS", systemImage: "location.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .contextMenu {
            Button(role: .destructive) {
                modelContext.delete(pin)
                try? modelContext.save()
            } label: {
                Label("Delete Photo", systemImage: "trash")
            }
        }
    }
}

// MARK: - Hex color helper

extension Color {
    init(hexString: String) {
        let hex = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0xFF6B35
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

#if DEBUG
#Preview("Projects panel") {
    @Previewable @State var active: Set<PersistentIdentifier> = []
    ProjectsPanel(activeListIDs: $active)
        .frame(width: 240, height: 600)
        .modelContainer(PreviewData.container)
}
#endif
