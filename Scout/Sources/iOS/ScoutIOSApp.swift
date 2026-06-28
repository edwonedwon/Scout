// ScoutIOSApp.swift
// Real, data-backed iOS app shell (browse-first).
// Wired to the PowerSync-backed store via the shared VM adapter (ProjectVM / ListVM / PinVM /
// ScriptVM from StoreVMs.swift) — the same reference-type VMs the Mac UI uses, so the two platforms
// share one data layer and sync live. iOS-specific display helpers live in IOSStoreSupport.swift.

#if os(iOS)
import SwiftUI
import MapKit
import ScoutKit

// MARK: - Sync status pill (connection state; tap to reconnect)

struct SyncStatusPill: View {
    @ObservedObject private var status = SyncStatusModel.shared
    var body: some View {
        Button {
            Task { await ScoutStore.shared.connectIfPossible() }
        } label: {
            if status.downloading || status.uploading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: status.connected ? "checkmark.icloud" : "icloud.slash")
                    .font(.subheadline)
                    .foregroundStyle(status.connected ? Color.green : .secondary)
            }
        }
    }
}

// MARK: - Reusable pin thumbnail (wraps the shared cached image view)

struct IOSPinThumb: View {
    @ObservedObject var pin: PinVM
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
    @ObservedObject private var store = MacStore.shared
    @State private var activeProject: ProjectVM?

    private var projects: [ProjectVM] {
        store.projects.filter { $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
    }

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
            if env["SCOUT_SEED"] != nil, projects.isEmpty { Task { await seedSampleProject() } }
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
                        Button("New Project") { Task { await createProject() } }
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
                ToolbarItem(placement: .topBarLeading) { SyncStatusPill() }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await createProject() } } label: { Label("New Project", systemImage: "plus") }
                        #if DEBUG
                        Button { Task { await seedSampleProject() } } label: { Label("Add Sample Data", systemImage: "wand.and.stars") }
                        #endif
                    } label: { Image(systemName: "plus") }
                }
            }
        }
    }

    private func createProject() async {
        guard let id = try? await ScoutStore.shared.createProject(name: "New Project") else { return }
        // The watch stream delivers the new project; select it once its VM exists.
        for _ in 0..<20 {
            if let vm = store.projects.first(where: { $0.id == id }) {
                withAnimation { activeProject = vm }
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func deleteProjects(_ offsets: IndexSet) {
        let targets = offsets.map { projects[$0] }
        for p in targets { p.deletedAt = Date() }   // VM write-through soft-deletes via the store
    }

    #if DEBUG
    /// DEBUG-only seed so a fresh store has something to browse.
    private func seedSampleProject() async {
        let store = ScoutStore.shared
        guard let projectId = try? await store.createProject(name: "Tokyo — Spring 2026") else { return }
        let seeds: [(String, String, [(String, String, Double, Double)])] = [
            ("Day 1 — Shinjuku", ListVM.palette[0], [
                ("Shinjuku Gyoen", "Great light at golden hour", 35.6852, 139.7100),
                ("Golden Gai", "Narrow alley bars", 35.6940, 139.7032),
                ("Omoide Yokocho", "Steam and lanterns at dusk", 35.6939, 139.7001),
            ]),
            ("Day 2 — Shibuya", ListVM.palette[1], [
                ("Shibuya Crossing", "Wide angle from the window", 35.6595, 139.7004),
                ("Miyashita Park", "Rooftop skyline framing", 35.6610, 139.7039),
            ]),
            ("Day 3 — Asakusa", ListVM.palette[2], [
                ("Senso-ji Temple", "Pre-dawn, before crowds", 35.7147, 139.7966),
                ("Nakamise-dori", "Leading lines down the street", 35.7133, 139.7960),
            ]),
        ]
        for (li, (name, color, pins)) in seeds.enumerated() {
            guard let listId = try? await store.createList(projectId: projectId, name: name, colorHex: color, panelOrder: li) else { continue }
            for (pi, p) in pins.enumerated() {
                let rec = PinRecord(
                    id: ScoutStore.newID(), listId: listId, owningProjectId: nil,
                    name: p.0, notes: p.1, latitude: p.2, longitude: p.3,
                    hasGPS: true, gpsFromTimeline: false, isFlagged: false,
                    rotationQuarterTurns: 0, aspectRatio: 0, panelOrder: 0, sortOrder: pi,
                    statusRaw: LocationStatus.scouted.rawValue,
                    imageSourceRaw: ScoutImage.ImageSource.googleMaps.rawValue,
                    imageURL: "https://picsum.photos/seed/\(p.0.lowercased().replacingOccurrences(of: " ", with: "-"))/700/525",
                    googlePlaceId: nil, googleMapsURL: nil, sourceURL: nil, originalFilename: nil,
                    photoFiles: [], thumbnailFiles: [], dateTaken: nil, createdAt: Date(), deletedAt: nil
                )
                _ = try? await store.insertPin(rec)
            }
        }
    }
    #endif
}

// MARK: - In-project shell (tabs + sidebar drawer)

struct InProjectShell: View {
    @ObservedObject var project: ProjectVM
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
    @State private var mapFocusPin: PinVM?

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
    @ObservedObject var project: ProjectVM
    @Binding var visibleListIDs: Set<UUID>
    let onBackToProjects: () -> Void
    let onClose: () -> Void
    let onOpenPinOnMap: (PinVM) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var search = ""
    @State private var showShare = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    listsSectionHeader
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
            // Account-based sharing (project_members + RLS).
            ShareProjectView(projectId: project.uuid.uuidString, projectName: project.name)
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
                // Share replaces the close button — tapping outside the drawer dismisses it.
                Button { showShare = true } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
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

    /// True when every list in the project is currently toggled visible.
    private var allListsVisible: Bool {
        let ids = project.allListIDs
        return !ids.isEmpty && ids.allSatisfy { visibleListIDs.contains($0) }
    }

    /// Show or hide every list at once (the iOS equivalent of the Mac "All Lists" eye).
    private func toggleAllVisibility() {
        let ids = project.allListIDs
        if allListsVisible { visibleListIDs.subtract(ids) } else { visibleListIDs.formUnion(ids) }
    }

    /// "LISTS" header with a master eye that flips every list's visibility in one tap.
    private var listsSectionHeader: some View {
        HStack {
            Text("LISTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Button(action: toggleAllVisibility) {
                Image(systemName: allListsVisible ? "eye.fill" : "eye.slash")
                    .font(.subheadline)
                    .foregroundStyle(allListsVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private func folderRows(_ folder: ListVM) -> some View {
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
    private func leafListRow(_ list: ListVM, indent: Int, parentVisible: Bool) -> some View {
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
    private func pinRow(_ pin: PinVM, indent: Int) -> some View {
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
#endif
