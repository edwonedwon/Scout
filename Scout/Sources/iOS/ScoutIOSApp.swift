// ScoutIOSApp.swift
// Real, data-backed iOS app shell (Milestone 1: browse-first).
// Replaces the former mock `iOSLayoutPreview.swift`. Wired to the shared Core Data
// entities (ProjectData / LocationListData / PinnedLocationData / ScriptData) and reuses
// the Mac app's services & helpers (GooglePhotoImage, Color(hexString:), FountainParser…).

#if os(iOS)
import SwiftUI
import CoreData
import MapKit
import ScoutKit

// MARK: - Entity display helpers

extension ProjectData {
    /// Top-level lists (not nested), in panel order, excluding trashed.
    var topLevelLists: [LocationListData] {
        liveLists.filter { $0.parentList == nil }.sorted { $0.panelOrder < $1.panelOrder }
    }
    /// Every (live) list id — used to seed "all visible" on the map.
    var allListIDs: Set<UUID> { Set(liveLists.map(\.uuid)) }
    /// Pins belonging to the lists currently toggled visible.
    func visiblePins(_ visible: Set<UUID>) -> [PinnedLocationData] {
        liveLists.filter { visible.contains($0.uuid) }.flatMap { $0.livePins }
    }
    /// All pins in the project (for default map framing).
    var allMapPins: [PinnedLocationData] { liveLists.flatMap { $0.livePins } + livePhotos }
    var pinCount: Int { allMapPins.count }
}

extension LocationListData {
    var displayColor: Color { Color(hexString: colorHex) }
    var iosSortedChildren: [LocationListData] { liveChildLists.sorted { $0.panelOrder < $1.panelOrder } }
    var sortedPins: [PinnedLocationData] { livePins.sorted { $0.sortOrder < $1.sortOrder } }
    var isFolder: Bool { !liveChildLists.isEmpty }
    /// Pins in this list plus any in its child lists (folder rollup count).
    var rollupPinCount: Int { livePins.count + liveChildLists.reduce(0) { $0 + $1.livePins.count } }
}

extension PinnedLocationData {
    var displayColor: Color { Color(hexString: list?.colorHex ?? LocationListData.palette[0]) }
    /// Best thumbnail URL: a stored thumbnail file, else the remote source image.
    var thumbURL: URL? { thumbnailImages.first?.url ?? imageURL.flatMap { URL(string: $0) } }
}

// MARK: - Reusable pin thumbnail (wraps the shared cached image view)

struct IOSPinThumb: View {
    let pin: PinnedLocationData
    var targetPixelSize: CGFloat? = nil
    var cornerRadius: CGFloat = 0

    var body: some View {
        GooglePhotoImage(
            url: pin.thumbURL,
            rotationQuarterTurns: pin.rotationQuarterTurns,
            targetPixelSize: targetPixelSize,
            displayName: pin.name
        ) {
            Rectangle()
                .fill(Color(.systemGray5))
                .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
        }
        .aspectRatio(contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// MARK: - Root: project list → in-project shell

struct ScoutIOSRootView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \ProjectData.createdAt, ascending: false)],
        predicate: NSPredicate(format: "deletedAt == nil")
    ) private var projects: FetchedResults<ProjectData>

    @State private var activeProject: ProjectData?

    var body: some View {
        Group {
            if let project = activeProject {
                InProjectShell(project: project, onSwitchProject: {
                    withAnimation(.easeInOut(duration: 0.28)) { activeProject = nil }
                })
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            } else {
                projectList
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)))
            }
        }
        #if DEBUG
        .onAppear {
            // Launch-arg hooks for automated screenshot verification (no UI tapping needed).
            let env = ProcessInfo.processInfo.environment
            if env["SCOUT_SEED"] != nil, projects.isEmpty { seedSampleProject() }
            if env["SCOUT_OPEN_FIRST"] != nil, activeProject == nil { activeProject = projects.first }
        }
        #endif
    }

    private var projectList: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView {
                        Label("No Projects", systemImage: "folder")
                    } description: {
                        Text("Create a project to start scouting locations.")
                    } actions: {
                        Button("New Project") { createProject() }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(projects) { project in
                            Button {
                                withAnimation(.easeInOut(duration: 0.28)) { activeProject = project }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill")
                                        .font(.title3).foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).font(.body).foregroundStyle(.primary)
                                        Text("\(project.topLevelLists.count) lists · \(project.pinCount) locations")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: deleteProjects)
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { createProject() } label: { Label("New Project", systemImage: "plus") }
                        #if DEBUG
                        Button { seedSampleProject() } label: { Label("Add Sample Data", systemImage: "wand.and.stars") }
                        #endif
                    } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func createProject() {
        let project = ProjectData(context: context, name: "New Project")
        try? context.save()
        withAnimation { activeProject = project }
    }

    private func deleteProjects(_ offsets: IndexSet) {
        for index in offsets { projects[index].deletedAt = Date() }
        try? context.save()
    }

    #if DEBUG
    /// DEBUG-only seed so a fresh (CloudKit-off) store has something to browse.
    private func seedSampleProject() {
        let project = ProjectData(context: context, name: "Tokyo — Spring 2026")
        let seeds: [(String, String, [(String, String, Double, Double)])] = [
            ("Day 1 — Shinjuku", LocationListData.palette[0], [
                ("Shinjuku Gyoen", "Great light at golden hour", 35.6852, 139.7100),
                ("Golden Gai", "Narrow alley bars", 35.6940, 139.7032),
                ("Omoide Yokocho", "Steam and lanterns at dusk", 35.6939, 139.7001),
            ]),
            ("Day 2 — Shibuya", LocationListData.palette[1], [
                ("Shibuya Crossing", "Wide angle from the window", 35.6595, 139.7004),
                ("Miyashita Park", "Rooftop skyline framing", 35.6610, 139.7039),
            ]),
            ("Day 3 — Asakusa", LocationListData.palette[2], [
                ("Senso-ji Temple", "Pre-dawn, before crowds", 35.7147, 139.7966),
                ("Nakamise-dori", "Leading lines down the street", 35.7133, 139.7960),
            ]),
        ]
        for (li, (name, color, pins)) in seeds.enumerated() {
            let list = LocationListData(context: context, name: name, colorHex: color)
            list.project = project
            list.panelOrder = li
            for (pi, p) in pins.enumerated() {
                let pin = PinnedLocationData(context: context)
                pin.name = p.0
                pin.notes = p.1
                pin.latitude = p.2
                pin.longitude = p.3
                pin.statusRaw = "scouted"
                pin.sortOrder = pi
                pin.imageURL = "https://picsum.photos/seed/\(p.0.lowercased().replacingOccurrences(of: " ", with: "-"))/700/525"
                pin.list = list
            }
        }
        try? context.save()
    }
    #endif
}

// MARK: - In-project shell (tabs + sidebar drawer)

struct InProjectShell: View {
    @ObservedObject var project: ProjectData
    let onSwitchProject: () -> Void

    @State private var visibleListIDs: Set<UUID> = []
    @State private var selectedTab = {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["SCOUT_TAB"], let i = Int(t) { return i }
        #endif
        return 0
    }()
    @State private var showCamera = false
    @State private var showSidebar = false
    @State private var mapFocusPin: PinnedLocationData?

    private func openSidebar() { withAnimation(.easeOut(duration: 0.28)) { showSidebar = true } }
    private func closeSidebar() { withAnimation(.easeIn(duration: 0.24)) { showSidebar = false } }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                IOSMapTab(project: project, visibleListIDs: $visibleListIDs, focusPin: $mapFocusPin, onMenu: openSidebar)
                    .tabItem { Label("Map", systemImage: "map.fill") }
                    .tag(0)

                IOSPhotosTab(project: project, onMenu: openSidebar)
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag(1)

                Color.clear
                    .tabItem { Label("Camera", systemImage: "camera.fill") }
                    .tag(2)

                IOSScriptTab(project: project, onMenu: openSidebar)
                    .tabItem { Label("Script", systemImage: "doc.text.fill") }
                    .tag(3)

                IOSScoutTab(project: project, onMenu: openSidebar)
                    .tabItem { Label("Scout", systemImage: "figure.walk") }
                    .tag(4)
            }
            .onChange(of: selectedTab) { old, new in
                if new == 2 { selectedTab = old; showCamera = true }
            }

            if showSidebar {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeSidebar() }

                HStack(spacing: 0) {
                    IOSSidebarDrawer(
                        project: project,
                        visibleListIDs: $visibleListIDs,
                        onBackToProjects: onSwitchProject,
                        onClose: closeSidebar,
                        onOpenPinOnMap: { pin in
                            mapFocusPin = pin
                            selectedTab = 0
                            closeSidebar()
                        }
                    )
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .background(Color(.systemBackground))
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .leading))
            }
        }
        .onAppear {
            if visibleListIDs.isEmpty { visibleListIDs = project.allListIDs }
        }
        .fullScreenCover(isPresented: $showCamera) {
            IOSCameraSheet(project: project)
        }
    }
}

/// Hamburger button used in each tab's nav bar.
struct IOSMenuButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal").font(.body.weight(.semibold))
        }
    }
}

// MARK: - Sidebar drawer

/// The slide-in sidebar — the iOS equivalent of the Mac locations sidebar. Shows the
/// project's lists/folders with eye toggles (driving map visibility) and expansion.
/// Drag-to-reorder/nest is deferred to a later milestone.
struct IOSSidebarDrawer: View {
    @ObservedObject var project: ProjectData
    @Binding var visibleListIDs: Set<UUID>
    let onBackToProjects: () -> Void
    let onClose: () -> Void
    let onOpenPinOnMap: (PinnedLocationData) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var search = ""
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionHeader("LISTS")
                    ForEach(project.topLevelLists, id: \.uuid) { list in
                        if list.isFolder {
                            folderRows(list)
                        } else {
                            leafListRow(list, indent: 0, parentVisible: true)
                        }
                    }
                    if !project.livePhotos.isEmpty {
                        sectionHeader("UNCATEGORIZED")
                        ForEach(project.livePhotos, id: \.uuid) { pin in
                            pinRow(pin, indent: 0)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            searchBar
        }
        .tint(.accentColor)
        .sheet(isPresented: $showShare) {
            ProjectShareSheet(project: project, onDismiss: { showShare = false })
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onBackToProjects) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                Spacer()
                Button { showShare = true } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
            }
            Text(project.name).font(.title.bold()).lineLimit(2)
            Button { } label: {  // TODO M2: create list
                Label("New List", systemImage: "plus").font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search)  // TODO M2: filter
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.secondarySystemFill), in: Capsule())
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func folderRows(_ folder: LocationListData) -> some View {
        let isOpen = expanded.contains(folder.uuid)
        let folderVisible = visibleListIDs.contains(folder.uuid)
        HStack(spacing: 8) {
            expandChevron(folder.uuid, isOpen: isOpen)
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary)
            Text(folder.name).font(.body)
            Spacer()
            Text("\(folder.rollupPinCount)").font(.caption).foregroundStyle(.secondary)
            eyeButton(folder.uuid)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())

        if isOpen {
            ForEach(folder.iosSortedChildren, id: \.uuid) { child in
                leafListRow(child, indent: 1, parentVisible: folderVisible)
            }
        }
    }

    @ViewBuilder
    private func leafListRow(_ list: LocationListData, indent: Int, parentVisible: Bool) -> some View {
        let isOpen = expanded.contains(list.uuid)
        let visible = parentVisible && visibleListIDs.contains(list.uuid)
        HStack(spacing: 8) {
            if list.sortedPins.isEmpty {
                Spacer().frame(width: 16)
            } else {
                expandChevron(list.uuid, isOpen: isOpen)
            }
            Circle().fill(list.displayColor).frame(width: 11, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(list.name).font(.body)
                Text("\(list.livePins.count) locations").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            eyeButton(list.uuid)
        }
        .padding(.leading, 16 + CGFloat(indent) * 18).padding(.trailing, 16).padding(.vertical, 7)
        .opacity(visible ? 1 : 0.4)
        .contentShape(Rectangle())

        if isOpen {
            ForEach(list.sortedPins, id: \.uuid) { pin in
                pinRow(pin, indent: indent + 1)
            }
        }
    }

    @ViewBuilder
    private func pinRow(_ pin: PinnedLocationData, indent: Int) -> some View {
        Button {
            onOpenPinOnMap(pin)
        } label: {
            HStack(spacing: 8) {
                IOSPinThumb(pin: pin, targetPixelSize: 60, cornerRadius: 4)
                    .frame(width: 30, height: 30)
                Text(pin.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                Spacer()
            }
            .padding(.leading, 16 + CGFloat(indent) * 18).padding(.trailing, 16).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func expandChevron(_ id: UUID, isOpen: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOpen { expanded.remove(id) } else { expanded.insert(id) }
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 16)
        }
        .buttonStyle(.plain)
    }

    private func eyeButton(_ id: UUID) -> some View {
        Button {
            if visibleListIDs.contains(id) { visibleListIDs.remove(id) } else { visibleListIDs.insert(id) }
        } label: {
            Image(systemName: visibleListIDs.contains(id) ? "eye.fill" : "eye.slash")
                .font(.subheadline)
                .foregroundStyle(visibleListIDs.contains(id) ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Project List") {
    ScoutIOSRootView()
        .environment(\.managedObjectContext, PreviewData.context)
}
#endif
#endif
