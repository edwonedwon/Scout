import SwiftUI
import SwiftData
import ScoutKit

// MARK: - Projects panel

struct ProjectsPanel: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ProjectData.createdAt) private var projects: [ProjectData]

    @Binding var activeList: LocationListData?

    @State private var showAddProject = false
    @State private var newProjectName = ""
    @State private var addingListTo: ProjectData?
    @State private var newListName = ""

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
                ListCard(list: list, activeList: $activeList, modelContext: modelContext)
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
            Button { showAddProject = true } label: {
                Image(systemName: "plus").font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

// MARK: - List card (draggable, drop target, expandable)

private struct ListCard: View {
    let list: LocationListData
    @Binding var activeList: LocationListData?
    let modelContext: ModelContext

    @State private var isTargeted = false
    @State private var isExpanded = true

    private var isActive: Bool { activeList?.persistentModelID == list.persistentModelID }
    private var listColor: Color { Color(hexString: list.colorHex) }

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
                    isTargeted ? listColor : Color(nsColor: .separatorColor).opacity(0.6),
                    lineWidth: isTargeted ? 2 : 1
                )
        )
        .shadow(color: .black.opacity(isTargeted ? 0.12 : 0.04), radius: isTargeted ? 6 : 2, y: 1)
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
        .dropDestination(for: ScoutLocation.self) { items, _ in
            for loc in items {
                let pin = PinnedLocationData(from: loc)
                pin.list = list
                list.pins.append(pin)
                modelContext.insert(pin)
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
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
            Circle().fill(listColor).frame(width: 10, height: 10)

            Text(list.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            Text("\(list.pins.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            // Active-on-map indicator
            Image(systemName: "mappin.circle.fill")
                .font(.caption)
                .foregroundStyle(isActive ? listColor : Color.clear)

            // Expand/collapse chevron
            if !list.pins.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isTargeted ? listColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(duration: 0.2)) {
                activeList = isActive ? nil : list
            }
        }
    }

    private var pinnedLocations: some View {
        let sorted = list.pins.sorted(by: { $0.createdAt < $1.createdAt })
        return LazyVStack(spacing: 0) {
            ForEach(sorted) { pin in
                VStack(spacing: 0) {
                    LocationRow(location: pin.asScoutLocation())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button(role: .destructive) {
                                modelContext.delete(pin)
                            } label: {
                                Label("Remove from List", systemImage: "minus.circle")
                            }
                        }
                    if pin.persistentModelID != sorted.last?.persistentModelID {
                        Divider().padding(.leading, 10)
                    }
                }
            }
        }
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
