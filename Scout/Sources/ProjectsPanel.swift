import SwiftUI
import SwiftData
import ScoutKit
import CoreLocation
import UniformTypeIdentifiers
// MARK: - Shared drag state for moving/reordering saved pins
//
// Rather than serialize a pin identity through the pasteboard (which proved
// unreliable across separate ListCard views), we hold the actual dragged pin
// in a shared object. The drop reads the exact in-memory reference — no
// serialization, no UUID lookup, works identically within and across lists.

final class PinDragState: ObservableObject {
    var draggedPin: PinnedLocationData?
}

// MARK: - Projects panel

struct ProjectsPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectData.createdAt) private var projects: [ProjectData]

    @Binding var activeList: LocationListData?
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onPanToPin: ((CLLocationCoordinate2D) -> Void)? = nil

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
                list.project = project
                project.lists.append(list)
                modelContext.insert(list)
                addingListTo = nil
            }
        }
    }

    // MARK: - Project section

    private func projectSection(_ project: ProjectData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            projectHeader(project)

            let sorted = project.lists.sorted(by: { $0.createdAt < $1.createdAt })
            ForEach(sorted) { list in
                ListCard(list: list, activeList: $activeList, modelContext: modelContext,
                         showPinPhotos: showPinPhotos, dragState: dragState,
                         onFitToList: onFitToList, onPanToPin: onPanToPin)
            }

            Button {
                newListName = ""
                addingListTo = project
            } label: {
                Label("Add List", systemImage: "plus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private func projectHeader(_ project: ProjectData) -> some View {
        HStack {
            Text(project.name)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                if let active = activeList, active.project?.persistentModelID == project.persistentModelID {
                    activeList = nil
                }
                modelContext.delete(project)
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
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

// MARK: - List card

private struct ListCard: View {
    let list: LocationListData
    @Binding var activeList: LocationListData?
    let modelContext: ModelContext
    var showPinPhotos: Bool = false
    let dragState: PinDragState
    var onFitToList: (([PinnedLocationData]) -> Void)? = nil
    var onPanToPin: ((CLLocationCoordinate2D) -> Void)? = nil

    @State private var isTargeted = false         // ScoutLocation drop highlight
    @State private var isPinDropTarget = false    // PinnedPin drop highlight (move to list)
    @State private var insertBeforeID: PersistentIdentifier? = nil
    @State private var isExpanded = true
    @State private var isEditingName = false
    @State private var editingName = ""
    @FocusState private var nameFocused: Bool

    private var isActive: Bool { activeList?.persistentModelID == list.persistentModelID }
    private var listColor: Color { Color(hexString: list.colorHex) }
    private var isHighlighted: Bool { isTargeted || isPinDropTarget }

    var body: some View {
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
        // Drop from search results
        .dropDestination(for: ScoutLocation.self) { items, _ in
            for loc in items {
                let pin = PinnedLocationData(from: loc, sortOrder: list.pins.count)
                modelContext.insert(pin)
                pin.list = list   // inverse relationship adds it to list.pins
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            Button { beginEditing() } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                if isActive { activeList = nil }
                modelContext.delete(list)
            } label: {
                Label("Delete List", systemImage: "trash")
            }
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.spring(duration: 0.2)) {
                    activeList = isActive ? nil : list
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
                .opacity(list.pins.isEmpty ? 0 : 1)
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
        // Drop a pin onto the list title to move it here (works for empty lists too)
        .onDrop(of: [.text], isTargeted: $isPinDropTarget) { _ in
            guard let dragged = dragState.draggedPin else { return false }
            if dragged.list?.persistentModelID != list.persistentModelID {
                movePin(dragged, toList: list)
            } else {
                appendPin(dragged, in: sortedPins())
            }
            dragState.draggedPin = nil
            return true
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

                if showPinPhotos, let urlStr = pin.imageURL, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        default:
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 44, height: 44)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(String(format: "%.4f, %.4f", pin.latitude, pin.longitude))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, showPinPhotos && pin.imageURL != nil ? 6 : 4)
            .contentShape(Rectangle())
            .onTapGesture { onPanToPin?(pin.coordinate) }
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

    // MARK: - Lookup by stable UUID

    // MARK: - Sort + reorder helpers

    private func sortedPins() -> [PinnedLocationData] {
        list.pins.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }
    }

    private func reorder(pin dragged: PinnedLocationData, before target: PinnedLocationData, in sorted: [PinnedLocationData]) {
        guard dragged.persistentModelID != target.persistentModelID else { return }
        var pins = sorted.filter { $0.persistentModelID != dragged.persistentModelID }
        if let idx = pins.firstIndex(where: { $0.persistentModelID == target.persistentModelID }) {
            pins.insert(dragged, at: idx)
        }
        for (i, p) in pins.enumerated() { p.sortOrder = i }
    }

    private func appendPin(_ dragged: PinnedLocationData, in sorted: [PinnedLocationData]) {
        var pins = sorted.filter { $0.persistentModelID != dragged.persistentModelID }
        pins.append(dragged)
        for (i, p) in pins.enumerated() { p.sortOrder = i }
    }

    private func movePin(_ pin: PinnedLocationData, toList target: LocationListData,
                         before insertBefore: PinnedLocationData? = nil,
                         in sorted: [PinnedLocationData] = []) {
        // `list` has @Relationship(inverse:), so setting it moves the pin out of
        // its old list's `pins` and into the target's automatically.
        pin.list = target

        // Re-number the target list so the dropped pin lands in the right slot.
        let targetSorted = target.pins
            .filter { $0.persistentModelID != pin.persistentModelID }
            .sorted {
                $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder
                                             : $0.createdAt < $1.createdAt
            }
        var pins = targetSorted
        if let insertBefore,
           let idx = pins.firstIndex(where: { $0.persistentModelID == insertBefore.persistentModelID }) {
            pins.insert(pin, at: idx)
        } else {
            pins.append(pin)
        }
        for (i, p) in pins.enumerated() { p.sortOrder = i }
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
