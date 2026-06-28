// StoreIOSViews.swift — PowerSync-backed iOS browse UI (migration plan P2).
//
// A parallel iOS view tree that reads/writes ScoutStore (PowerSync SQLite) instead of Core Data.
// Built alongside the live Core Data tree (ScoutIOSApp.swift); RootGate only switches to it behind
// a DEBUG launch arg (SCOUT_STORE_UI) until the whole tree is ported and sync is verified, so the
// shipping app is untouched in the meantime. Slice 1: project list + the in-project list/pin tree.

#if os(iOS)
import SwiftUI
import ScoutKit

// The observable models (ProjectsListModel / ProjectTreeModel) now live in the shared
// StoreModels.swift so both platforms share one definition.

// MARK: - Root: project list

struct IOSStoreRootView: View {
    @StateObject private var model = ProjectsListModel()
    @State private var activeProject: ProjectRecord?

    var body: some View {
        Group {
            if let project = activeProject {
                IOSStoreProjectView(project: project, onBack: {
                    withAnimation(.easeInOut(duration: 0.28)) { activeProject = nil }
                })
                .transition(.move(edge: .trailing))
            } else {
                projectList
                    .transition(.move(edge: .leading))
            }
        }
    }

    private var projectList: some View {
        NavigationStack {
            Group {
                if model.summaries.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "folder")
                    } description: {
                        Text("Create a project to start scouting locations.")
                    } actions: {
                        Button("New Project") { Task { await create() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(model.summaries) { summary in
                            Button {
                                withAnimation(.easeInOut(duration: 0.28)) { activeProject = summary.project }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").font(.title3).foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(summary.project.name).font(.body).foregroundStyle(.primary)
                                        Text("\(summary.listCount) lists · \(summary.pinCount) locations")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { model.summaries[$0].id }
                            Task { for id in ids { await model.softDelete(id) } }
                        }
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await create() } } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func create() async {
        if let id = await model.create(name: "New Project") {
            // Reflect immediately; the watch stream will also deliver it.
            let project = ProjectRecord(id: id, name: "New Project")
            withAnimation { activeProject = project }
        }
    }
}

// MARK: - In-project: list / folder / pin tree (the iOS sidebar content, store-backed)

struct IOSStoreProjectView: View {
    @StateObject private var tree: ProjectTreeModel
    let onBack: () -> Void
    @State private var expanded: Set<String> = []

    init(project: ProjectRecord, onBack: @escaping () -> Void) {
        _tree = StateObject(wrappedValue: ProjectTreeModel(project: project))
        self.onBack = onBack
    }

    var body: some View {
        NavigationStack {
            List {
                Section("LISTS") {
                    ForEach(tree.topLevelLists) { list in
                        if tree.isFolder(list.id) {
                            folderRows(list)
                        } else {
                            leafRows(list, indent: 0)
                        }
                    }
                }
                if !tree.loosePhotos.isEmpty {
                    Section("UNCATEGORIZED") {
                        ForEach(tree.loosePhotos) { pin in pinRow(pin, indent: 0) }
                    }
                }
            }
            .navigationTitle(tree.project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onBack) { Image(systemName: "chevron.left") }
                }
            }
        }
    }

    @ViewBuilder
    private func folderRows(_ folder: ListRecord) -> some View {
        let isOpen = expanded.contains(folder.id)
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOpen { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 16)
                Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary)
                Text(folder.name).font(.body).foregroundStyle(.primary)
                Spacer()
                Text("\(tree.rollupPinCount(folder.id))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        if isOpen {
            ForEach(tree.children(of: folder.id)) { child in leafRows(child, indent: 1) }
        }
    }

    @ViewBuilder
    private func leafRows(_ list: ListRecord, indent: Int) -> some View {
        let isOpen = expanded.contains(list.id)
        let listPins = tree.pins(inList: list.id)
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOpen { expanded.remove(list.id) } else { expanded.insert(list.id) }
            }
        } label: {
            HStack(spacing: 8) {
                if listPins.isEmpty {
                    Spacer().frame(width: 16)
                } else {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 16)
                }
                Circle().fill(Color(hexString: list.colorHex)).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list.name).font(.body).foregroundStyle(.primary)
                    Text("\(listPins.count) locations").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.leading, CGFloat(indent) * 18)
        }
        .buttonStyle(.plain)
        if isOpen {
            ForEach(listPins) { pin in pinRow(pin, indent: indent + 1) }
        }
    }

    private func pinRow(_ pin: PinRecord, indent: Int) -> some View {
        HStack(spacing: 8) {
            IOSStorePinThumb(pin: pin, colorHex: tree.colorHex(forList: pin.listId))
                .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(pin.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(indent) * 18)
    }
}

/// Minimal record-based thumbnail. For now shows the remote source image (`imageURL`) when present;
/// local-file / Storage-backed thumbnails get wired when the Photos tab is ported.
struct IOSStorePinThumb: View {
    let pin: PinRecord
    let colorHex: String
    var body: some View {
        GooglePhotoImage(
            url: pin.imageURL.flatMap { URL(string: $0) },
            rotationQuarterTurns: pin.rotationQuarterTurns,
            targetPixelSize: 60,
            displayName: pin.name
        ) {
            Rectangle().fill(Color(hexString: colorHex).opacity(0.25))
                .overlay { Image(systemName: "photo").font(.caption2).foregroundStyle(.tertiary) }
        }
        .aspectRatio(contentMode: .fill)
    }
}
#endif
