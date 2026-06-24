import SwiftUI
import SwiftData
import ScoutKit
import CoreLocation
import UniformTypeIdentifiers

// MARK: - Finder drag helpers

let imageExtensions: Set<String> = ["jpg","jpeg","png","heic","heif","tiff","tif","webp","gif","bmp","raw","arw","cr2","nef","dng"]

func loadImageURLs(from providers: [NSItemProvider]) async -> [URL] {
    await withTaskGroup(of: URL?.self) { group in
        for provider in providers {
            group.addTask {
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

/// Adjust this to clear the traffic light buttons in the sidebar.
private let sidebarTopPadding: CGFloat = 35

// MARK: - Projects panel

struct ProjectsPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectData.createdAt) private var projects: [ProjectData]

    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onSelectPin: ((PinnedLocationData) -> Void)? = nil

    @State private var selectedProject: ProjectData? = nil
    @State private var showAddProject = false
    @State private var newProjectName = ""

    var body: some View {
        NavigationStack {
            projectList
                .navigationDestination(for: ProjectData.self) { project in
                    ProjectDetailView(
                        project: project,
                        activeListIDs: $activeListIDs,
                        onFitToList: onFitToList,
                        onSelectPin: onSelectPin
                    )
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
    }

    private var projectList: some View {
        List {
            Color.clear.frame(height: sidebarTopPadding).listRowBackground(Color.clear)
            ForEach(projects) { project in
                NavigationLink(value: project) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.headline)
                        let total = project.lists.count + project.importedPhotos.count
                        if total > 0 {
                            Text("\(project.lists.count) lists · \(project.importedPhotos.count) photos")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .contextMenu {
                    Button(role: .destructive) {
                        modelContext.delete(project)
                        try? modelContext.save()
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddProject = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

// MARK: - Sidebar item (unified photo + list)

private enum SidebarItem: Identifiable {
    case photo(PinnedLocationData)
    case list(LocationListData)

    var id: PersistentIdentifier {
        switch self {
        case .photo(let p): return p.persistentModelID
        case .list(let l): return l.persistentModelID
        }
    }

    var panelOrder: Int {
        switch self {
        case .photo(let p): return p.panelOrder
        case .list(let l): return l.panelOrder
        }
    }

    var createdAt: Date {
        switch self {
        case .photo(let p): return p.createdAt
        case .list(let l): return l.createdAt
        }
    }

    /// Stable drag identifier: "photo:<uuid>" or "list:<uuid>". Transferred as a
    /// plain String, which round-trips through the pasteboard with no UTType setup.
    var dragID: String {
        switch self {
        case .photo(let p): return "photo:\(p.uuid.uuidString)"
        case .list(let l): return "list:\(l.uuid.uuidString)"
        }
    }
}

// MARK: - Project detail (unified reorderable list)

private struct ProjectDetailView: View {
    @Bindable var project: ProjectData
    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onSelectPin: ((PinnedLocationData) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @State private var showAddList = false
    @State private var newListName = ""
    @State private var expandedListIDs: Set<PersistentIdentifier> = []
    @State private var topLevelDropTargeted = false

    private var sidebarItems: [SidebarItem] {
        let photos = project.importedPhotos.map { SidebarItem.photo($0) }
        let lists = project.lists.filter { $0.parentList == nil }.map { SidebarItem.list($0) }
        // Use createdAt as a stable tiebreaker so equal panelOrder values don't shuffle.
        return (photos + lists).sorted {
            $0.panelOrder != $1.panelOrder ? $0.panelOrder < $1.panelOrder : $0.createdAt < $1.createdAt
        }
    }

    /// Assigns sequential panelOrder values based on the current stable sort.
    /// Call on appear and whenever the item count changes to fix any gaps or duplicates.
    private func normalizeOrder() {
        for (i, item) in sidebarItems.enumerated() {
            switch item {
            case .photo(let p): if p.panelOrder != i { p.panelOrder = i }
            case .list(let l): if l.panelOrder != i { l.panelOrder = i }
            }
        }
    }

    /// Resolves a drag id ("photo:<uuid>" / "list:<uuid>") to its live SidebarItem.
    private func resolve(_ dragID: String) -> SidebarItem? {
        sidebarItems.first { $0.dragID == dragID }
    }

    /// Finds a pin anywhere in the project — top-level or inside any list.
    private func findPin(uuid: String) -> PinnedLocationData? {
        if let p = project.importedPhotos.first(where: { $0.uuid.uuidString == uuid }) { return p }
        for list in project.lists {
            if let p = list.pins.first(where: { $0.uuid.uuidString == uuid }) { return p }
        }
        return nil
    }

    /// Removes a pin from wherever it currently lives (list or top-level).
    private func detach(_ pin: PinnedLocationData) {
        if let list = pin.list {
            list.pins.removeAll { $0.persistentModelID == pin.persistentModelID }
            pin.list = nil
        }
        project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
        pin.owningProject = nil
    }

    // MARK: - Drop loading

    /// Loads drag payload from providers and dispatches to handleDrop on main actor.
    private func loadDrop(_ providers: [NSItemProvider], onto target: SidebarItem) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in _ = handleDrop(dragID, onto: target) }
        }
        return true
    }

    /// Moves a list pin to the top-level project. `atTop` places it first, otherwise last.
    private func loadDropToTopLevel(_ providers: [NSItemProvider], atTop: Bool) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                let uuid: String
                if dragID.hasPrefix("pin:") { uuid = String(dragID.dropFirst(4)) }
                else if dragID.hasPrefix("photo:") { uuid = String(dragID.dropFirst(6)) }
                else { return }
                guard let pin = findPin(uuid: uuid) else { return }
                guard pin.list != nil else { return } // already top-level, nothing to do
                detach(pin)
                pin.owningProject = project
                // Set panelOrder outside the current range so normalizeOrder places it correctly.
                pin.panelOrder = atTop ? -1 : sidebarItems.count + 1
                project.importedPhotos.append(pin)
                normalizeOrder()
                try? modelContext.save()
            }
        }
        return true
    }

    /// Loads drag payload and moves the pin into a list, optionally after a specific pin.
    private func loadDropPin(_ providers: [NSItemProvider], intoList list: LocationListData, afterPin: PinnedLocationData? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let dragID = object as? String else { return }
            Task { @MainActor in
                let uuid: String
                if dragID.hasPrefix("pin:") { uuid = String(dragID.dropFirst(4)) }
                else if dragID.hasPrefix("photo:") { uuid = String(dragID.dropFirst(6)) }
                else { return }
                guard let pin = findPin(uuid: uuid) else { return }
                detach(pin)
                if let after = afterPin, let idx = list.pins.firstIndex(where: { $0.persistentModelID == after.persistentModelID }) {
                    list.pins.insert(pin, at: idx + 1)
                } else {
                    list.pins.append(pin)
                }
                pin.list = list
                for (i, p) in list.pins.enumerated() { p.sortOrder = i }
                normalizeOrder()
                try? modelContext.save()
            }
        }
        return true
    }

    // MARK: - Drop handling

    /// Central drop handler for top-level sidebar items.
    private func handleDrop(_ dragID: String, onto target: SidebarItem) -> Bool {
        // Pin dragged from inside a list onto a top-level target.
        if dragID.hasPrefix("pin:") {
            let uuid = String(dragID.dropFirst(4))
            guard let pin = findPin(uuid: uuid) else { return false }
            switch target {
            case .list(let list):
                // Move into this list.
                if pin.list?.persistentModelID == list.persistentModelID { return false }
                detach(pin)
                pin.list = list
                list.pins.append(pin)
                for (i, p) in list.pins.enumerated() { p.sortOrder = i }
                normalizeOrder()
            case .photo(let targetPin):
                // Move out to top-level, placed near the target photo.
                detach(pin)
                pin.owningProject = project
                pin.panelOrder = targetPin.panelOrder
                project.importedPhotos.append(pin)
                normalizeOrder()
            }
            try? modelContext.save()
            return true
        }

        // Top-level item dragged onto another top-level item.
        guard let dragged = resolve(dragID) else { return false }
        if dragged.id == target.id { return false }

        // Top-level photo dragged onto a list → move into list.
        if case .photo(let pin) = dragged, case .list(let list) = target {
            detach(pin)
            pin.list = list
            list.pins.append(pin)
            for (i, p) in list.pins.enumerated() { p.sortOrder = i }
            normalizeOrder()
            try? modelContext.save()
            return true
        }

        // Otherwise reorder.
        reorder(dragged, before: target)
        return true
    }

    /// Reorders `dragged` to sit at `target`'s current position in the sidebar.
    private func reorder(_ dragged: SidebarItem, before target: SidebarItem) {
        var items = sidebarItems
        guard let from = items.firstIndex(where: { $0.id == dragged.id }) else { return }
        let moving = items.remove(at: from)
        guard let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.insert(moving, at: to)
        for (i, item) in items.enumerated() {
            switch item {
            case .photo(let p): p.panelOrder = i
            case .list(let l): l.panelOrder = i
            }
        }
        try? modelContext.save()
    }

    var body: some View {
        List {
            Color.clear.frame(height: sidebarTopPadding).listRowBackground(Color.clear)

            // Drop zone: drag any list pin here to move it to the top-level project.
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.up")
                    .font(.caption)
                Text("Drop here to remove from list")
                    .font(.caption)
            }
            .foregroundStyle(topLevelDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(topLevelDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .padding(.horizontal, 4)
            )
            .listRowBackground(Color.clear)
            .onDrop(of: [.text], isTargeted: $topLevelDropTargeted) { providers in
                loadDropToTopLevel(providers, atTop: true)
            }

            ForEach(sidebarItems) { item in
                switch item {
                case .photo(let pin):
                    PinRow(pin: pin, onSelectPin: onSelectPin)
                        .contextMenu {
                            Button(role: .destructive) {
                                project.importedPhotos.removeAll { $0.persistentModelID == pin.persistentModelID }
                                modelContext.delete(pin)
                                try? modelContext.save()
                            } label: {
                                Label("Delete Photo", systemImage: "trash")
                            }
                        }
                        .onDrag { NSItemProvider(object: item.dragID as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { providers in
                            loadDrop(providers, onto: .photo(pin))
                        }
                case .list(let list):
                    let isExpanded = expandedListIDs.contains(list.persistentModelID)
                    ListRow(
                        list: list,
                        isExpanded: isExpanded,
                        onToggleExpand: {
                            if isExpanded { expandedListIDs.remove(list.persistentModelID) }
                            else { expandedListIDs.insert(list.persistentModelID) }
                        },
                        activeListIDs: $activeListIDs,
                        onFitToList: onFitToList,
                        onSelectPin: onSelectPin
                    )
                    .onDrag { NSItemProvider(object: item.dragID as NSString) }
                    .onDrop(of: [.text], isTargeted: nil) { providers in
                        loadDrop(providers, onto: .list(list))
                    }

                    if isExpanded {
                        let pins = list.pins.sorted { $0.sortOrder < $1.sortOrder }
                        ForEach(pins) { pin in
                            PinRow(pin: pin, onSelectPin: onSelectPin)
                                .padding(.leading, 24)
                                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 0))
                                .onDrag { NSItemProvider(object: "pin:\(pin.uuid.uuidString)" as NSString) }
                                .onDrop(of: [.text], isTargeted: nil) { providers in
                                    loadDropPin(providers, intoList: list, afterPin: pin)
                                }
                        }
                    }
                }
            }

            // Bottom drop zone — same as the top one, for when the list is scrolled down.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .listRowBackground(Color.clear)
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    loadDropToTopLevel(providers, atTop: false)
                }
        }
        .onAppear { normalizeOrder() }
        .onChange(of: project.importedPhotos.count) { normalizeOrder() }
        .onChange(of: project.lists.count) { normalizeOrder() }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newListName = ""
                        showAddList = true
                    } label: {
                        Label("New List", systemImage: "list.bullet")
                    }
                    Button { importPhotos() } label: {
                        Label("Import Photos", systemImage: "photo.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showAddList) {
            NameEntrySheet(
                title: "New List in \(project.name)",
                placeholder: "List name",
                text: $newListName,
                onDismiss: { showAddList = false }
            ) { name in
                let colorHex = LocationListData.palette[project.lists.count % LocationListData.palette.count]
                let list = LocationListData(name: name, colorHex: colorHex)
                list.panelOrder = sidebarItems.count
                modelContext.insert(list)
                list.project = project
                project.lists.append(list)
                try? modelContext.save()
                showAddList = false
            }
        }
    }

    private func importPhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let results = await PhotoImportService.importPhotos(from: urls, into: nil)
            var nextOrder = sidebarItems.count
            for result in results {
                result.pin.panelOrder = nextOrder
                nextOrder += 1
                modelContext.insert(result.pin)
                project.importedPhotos.append(result.pin)
            }
            try? modelContext.save()
        }
    }
}

// MARK: - List row (expand in place to see pins)

private struct ListRow: View {
    let list: LocationListData
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    @Binding var activeListIDs: Set<PersistentIdentifier>
    var onFitToList: (([PinnedLocationData]) -> Void)?
    var onSelectPin: ((PinnedLocationData) -> Void)?
    @Environment(\.modelContext) private var modelContext

    private var isActive: Bool { activeListIDs.contains(list.persistentModelID) }
    private var listColor: Color { Color(hexString: list.colorHex) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Circle()
                .fill(listColor)
                .frame(width: 10, height: 10)
            Text(list.name)
                .font(.body)
            Spacer()
            if !list.pins.isEmpty {
                Text("\(list.pins.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                if isActive { activeListIDs.remove(list.persistentModelID) }
                else { activeListIDs.insert(list.persistentModelID) }
            } label: {
                Image(systemName: isActive ? "eye.fill" : "eye")
                    .foregroundStyle(isActive ? listColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                if isActive { activeListIDs.remove(list.persistentModelID) }
                else { activeListIDs.insert(list.persistentModelID) }
            } label: {
                Label(isActive ? "Hide on Map" : "Show on Map", systemImage: isActive ? "eye.slash" : "eye")
            }
            if let onFitToList {
                Button {
                    onFitToList(list.pins.filter { $0.hasGPS })
                } label: {
                    Label("Fit Map to List", systemImage: "mappin.and.ellipse")
                }
            }
            Divider()
            Button(role: .destructive) {
                activeListIDs.remove(list.persistentModelID)
                modelContext.delete(list)
                try? modelContext.save()
            } label: {
                Label("Delete List", systemImage: "trash")
            }
        }
    }
}

// MARK: - Pin row (shared by photos and list pins)

private struct PinRow: View {
    let pin: PinnedLocationData
    var onSelectPin: ((PinnedLocationData) -> Void)?

    var body: some View {
        Button {
            onSelectPin?(pin)
        } label: {
            HStack(spacing: 10) {
                thumbnail
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let filename = pin.photoFiles.first {
            AsyncImage(url: PinPhotoStore.fileURL(filename)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
        } else if let urlString = pin.imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
                .overlay(
                    Image(systemName: "mappin")
                        .foregroundStyle(.secondary)
                )
        }
    }
}

// MARK: - OutlineGroup children helper

extension LocationListData {
    var sortedChildren: [LocationListData]? {
        let children = childLists.sorted { $0.sortOrder < $1.sortOrder }
        return children.isEmpty ? nil : children
    }
}

// MARK: - Name entry sheet

struct NameEntrySheet: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onDismiss: () -> Void
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !text.isEmpty { onConfirm(text) } }
            HStack {
                Button("Cancel", action: onDismiss)
                Spacer()
                Button("Create") { onConfirm(text) }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}

// MARK: - Previews

#Preview("Projects list") {
    ProjectsPanel(activeListIDs: .constant([]))
        .frame(width: 280, height: 600)
        .modelContainer(for: [ProjectData.self, LocationListData.self, PinnedLocationData.self], inMemory: true)
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
