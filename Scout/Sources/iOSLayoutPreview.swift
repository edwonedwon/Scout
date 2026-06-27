// iOSLayoutPreview.swift
// Standalone UI mockup of the proposed iOS Scout app layout.
// Uses 100% fake data — no SwiftData, no live services.
// Open any #Preview below in Xcode to explore the proposed UI.

#if os(iOS) && DEBUG
import SwiftUI
import MapKit
import UniformTypeIdentifiers

// MARK: - Mock data

struct MockPin: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var notes: String
    var lat: Double
    var lng: Double
    var imageName: String?
    var listColor: Color
    var dateTaken: Date?
}

struct MockList: Identifiable {
    let id = UUID()
    var name: String
    var color: Color
    var pins: [MockPin]
    var children: [MockList] = []

    var isFolder: Bool { !children.isEmpty }
    var totalPinCount: Int { pins.count + children.reduce(0) { $0 + $1.pins.count } }
    var leafLists: [MockList] { isFolder ? children : [self] }
}

struct MockProject: Identifiable {
    let id = UUID()
    var name: String
    var lists: [MockList]
    var uncategorized: [MockPin]
}

extension MockPin {
    /// A deterministic placeholder photo per pin. Lorem Picsum returns a stable image
    /// for a given seed — generic stock photography standing in for real location shots.
    /// (Swap these for bundled Japan photos / live SwiftData images when wired up.)
    var photoSeed: String {
        let base = imageName ?? name
        return String(base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
    func imageURL(width: Int, height: Int) -> URL? {
        URL(string: "https://picsum.photos/seed/\(photoSeed)/\(width)/\(height)")
    }
}

/// Reusable async photo with a graceful placeholder.
private struct MockPhoto: View {
    let pin: MockPin
    var width: Int = 700
    var height: Int = 525
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: pin.imageURL(width: width, height: height)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                placeholder
            default:
                ZStack { placeholder; ProgressView().tint(.secondary) }
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color(.systemGray5))
            .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
    }
}

private extension MockProject {
    var leafLists: [MockList] { lists.flatMap(\.leafLists) }
    var allPins: [MockPin] { leafLists.flatMap(\.pins) + uncategorized }
    /// All leaf list IDs — used to initialise the "all visible" default state.
    var allLeafListIDs: Set<UUID> { Set(leafLists.map(\.id)) }
}

// MARK: - Mutating helpers (drive sidebar drag & drop)

extension MockProject {
    /// Pull a list out of wherever it lives (top level or inside a folder).
    mutating func extractList(_ id: UUID) -> MockList? {
        if let idx = lists.firstIndex(where: { $0.id == id }) {
            return lists.remove(at: idx)
        }
        for i in lists.indices {
            if let idx = lists[i].children.firstIndex(where: { $0.id == id }) {
                return lists[i].children.remove(at: idx)
            }
        }
        return nil
    }

    /// Drop one list onto another → the target becomes a folder containing it.
    mutating func nestList(_ draggedID: UUID, into targetID: UUID) {
        guard draggedID != targetID, let dragged = extractList(draggedID) else { return }
        if let idx = lists.firstIndex(where: { $0.id == targetID }) {
            lists[idx].children.append(dragged)
            return
        }
        // Target is itself a child — append into that child (one extra nesting level).
        for i in lists.indices {
            if let idx = lists[i].children.firstIndex(where: { $0.id == targetID }) {
                lists[i].children[idx].children.append(dragged)
                return
            }
        }
    }

    /// Reorder a list relative to a target at the target's level.
    mutating func reorderList(_ draggedID: UUID, near targetID: UUID, after: Bool) {
        guard draggedID != targetID, let dragged = extractList(draggedID) else { return }
        if let idx = lists.firstIndex(where: { $0.id == targetID }) {
            lists.insert(dragged, at: after ? idx + 1 : idx)
            return
        }
        for i in lists.indices {
            if let idx = lists[i].children.firstIndex(where: { $0.id == targetID }) {
                lists[i].children.insert(dragged, at: after ? idx + 1 : idx)
                return
            }
        }
        lists.append(dragged)
    }

    /// Move a list back out to the top level.
    mutating func promoteList(_ draggedID: UUID) {
        guard let dragged = extractList(draggedID) else { return }
        lists.append(dragged)
    }

    mutating func extractPin(_ id: UUID) -> MockPin? {
        if let idx = uncategorized.firstIndex(where: { $0.id == id }) {
            return uncategorized.remove(at: idx)
        }
        for i in lists.indices {
            if let idx = lists[i].pins.firstIndex(where: { $0.id == id }) {
                return lists[i].pins.remove(at: idx)
            }
            for j in lists[i].children.indices {
                if let idx = lists[i].children[j].pins.firstIndex(where: { $0.id == id }) {
                    return lists[i].children[j].pins.remove(at: idx)
                }
            }
        }
        return nil
    }

    mutating func withLeafList(_ id: UUID, _ body: (inout MockList) -> Void) {
        for i in lists.indices {
            if lists[i].id == id { body(&lists[i]); return }
            for j in lists[i].children.indices {
                if lists[i].children[j].id == id { body(&lists[i].children[j]); return }
            }
        }
    }

    /// Move a pin into a list (appended at the end).
    mutating func movePin(_ pinID: UUID, intoList listID: UUID) {
        guard let pin = extractPin(pinID) else { return }
        withLeafList(listID) { $0.pins.append(pin) }
    }

    /// Reorder a pin relative to another pin (works within or across lists).
    mutating func reorderPin(_ pinID: UUID, nearPin targetPinID: UUID, after: Bool) {
        guard pinID != targetPinID, let pin = extractPin(pinID) else { return }
        func insert(_ list: inout MockList) -> Bool {
            if let idx = list.pins.firstIndex(where: { $0.id == targetPinID }) {
                list.pins.insert(pin, at: after ? idx + 1 : idx)
                return true
            }
            return false
        }
        for i in lists.indices {
            if insert(&lists[i]) { return }
            for j in lists[i].children.indices {
                if insert(&lists[i].children[j]) { return }
            }
        }
        if let idx = uncategorized.firstIndex(where: { $0.id == targetPinID }) {
            uncategorized.insert(pin, at: after ? idx + 1 : idx)
        }
    }
}

// MARK: - Sidebar drag & drop plumbing

/// Where on a row a drop landed: above it, on it (nest / move-into), or below it.
private enum DropZone: Equatable { case before, into, after }

private struct DropHighlight: Equatable {
    let id: UUID
    let zone: DropZone
}

/// What a droppable row represents — controls which drops are legal.
private enum RowTargetKind: Equatable {
    case list(canNest: Bool)
    case pin
}

private struct SidebarDropDelegate: DropDelegate {
    let targetID: UUID
    let kind: RowTargetKind
    let rowHeight: CGFloat
    @Binding var highlight: DropHighlight?
    let onPerform: (String, DropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropEntered(info: DropInfo) {
        highlight = DropHighlight(id: targetID, zone: zone(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        highlight = DropHighlight(id: targetID, zone: zone(info))
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if highlight?.id == targetID { highlight = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone(info)
        highlight = nil
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let payload = obj as? String else { return }
            DispatchQueue.main.async { onPerform(payload, z) }
        }
        return true
    }

    private func zone(_ info: DropInfo) -> DropZone {
        switch kind {
        case .pin:
            // Pins only reorder — pick the nearer edge.
            return info.location.y < rowHeight / 2 ? .before : .after
        case .list(let canNest):
            guard canNest else {
                return info.location.y < rowHeight / 2 ? .before : .after
            }
            let third = rowHeight / 3
            if info.location.y < third { return .before }
            if info.location.y > third * 2 { return .after }
            return .into
        }
    }
}

/// Wraps a row so it can both initiate a drag and accept drops, with a live drop indicator.
private struct DraggableRow<Content: View>: View {
    let dragPayload: String
    let targetID: UUID
    let kind: RowTargetKind
    @Binding var highlight: DropHighlight?
    let onPerform: (String, DropZone) -> Void
    @ViewBuilder var content: () -> Content

    @State private var height: CGFloat = 44

    private var hl: DropHighlight? { highlight?.id == targetID ? highlight : nil }

    var body: some View {
        content()
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { height = g.size.height }
                        .onChange(of: g.size.height) { _, h in height = h }
                }
            )
            .background(alignment: .center) {
                if hl?.zone == .into {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
                }
            }
            .overlay(alignment: .top) {
                if hl?.zone == .before {
                    Capsule().fill(Color.accentColor).frame(height: 2.5)
                }
            }
            .overlay(alignment: .bottom) {
                if hl?.zone == .after {
                    Capsule().fill(Color.accentColor).frame(height: 2.5)
                }
            }
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: dragPayload as NSString) }
            .onDrop(
                of: [UTType.text],
                delegate: SidebarDropDelegate(
                    targetID: targetID, kind: kind, rowHeight: height,
                    highlight: $highlight, onPerform: onPerform
                )
            )
    }
}

// MARK: - Mock content

private let tokyoProject = MockProject(
    name: "Tokyo — Spring 2026",
    lists: [
        MockList(name: "Day 1 — Shinjuku", color: .orange, pins: [
            MockPin(name: "Shinjuku Gyoen", notes: "Great light at golden hour through the cherry trees", lat: 35.6852, lng: 139.7100, listColor: .orange, dateTaken: Date()),
            MockPin(name: "Golden Gai", notes: "Narrow alley bars, incredible texture", lat: 35.6940, lng: 139.7032, listColor: .orange),
            MockPin(name: "Omoide Yokocho", notes: "Steam and lanterns — shoot at dusk", lat: 35.6939, lng: 139.7001, listColor: .orange, dateTaken: Date()),
        ]),
        MockList(name: "Day 2 — Shibuya", color: .blue, pins: [
            MockPin(name: "Shibuya Crossing", notes: "Wide angle from Starbucks window", lat: 35.6595, lng: 139.7004, listColor: .blue),
            MockPin(name: "Miyashita Park", notes: "Rooftop has good skyline framing", lat: 35.6610, lng: 139.7039, listColor: .blue, dateTaken: Date()),
            MockPin(name: "Daikanyama T-Site", notes: "Cozy bookstore, diffused afternoon light", lat: 35.6488, lng: 139.7024, listColor: .blue),
        ]),
        MockList(name: "Day 3 — Asakusa", color: .green, pins: [
            MockPin(name: "Senso-ji Temple", notes: "Pre-dawn, before crowds. Long exposure on the lantern.", lat: 35.7147, lng: 139.7966, listColor: .green, dateTaken: Date()),
            MockPin(name: "Nakamise-dori", notes: "Leading lines down the shopping street", lat: 35.7133, lng: 139.7960, listColor: .green),
        ]),
        MockList(name: "Cycling Roads", color: .gray, pins: [], children: [
            MockList(name: "View From Road", color: .blue, pins: [
                MockPin(name: "Arakawa Riverside", notes: "Long flat path, mountains in the distance", lat: 35.7600, lng: 139.7800, listColor: .blue, dateTaken: Date()),
            ]),
            MockList(name: "Riverside Path", color: .teal, pins: [
                MockPin(name: "Tamagawa Bank", notes: "Golden grass at sunset", lat: 35.6000, lng: 139.6500, listColor: .teal),
                MockPin(name: "Cherry Tunnel", notes: "Blossoms arch over the path in spring", lat: 35.6100, lng: 139.6600, listColor: .teal, dateTaken: Date()),
            ]),
        ]),
    ],
    uncategorized: [
        MockPin(name: "Yanaka Cemetery", notes: "Found this by accident — cats everywhere", lat: 35.7261, lng: 139.7660, listColor: .gray),
    ]
)

private let osakaProject = MockProject(
    name: "Osaka — Industrial",
    lists: [
        MockList(name: "Warehouses", color: .purple, pins: [
            MockPin(name: "Namba Freight Depot", notes: "High ceilings, shafts of light", lat: 34.6620, lng: 135.5010, listColor: .purple, dateTaken: Date()),
        ]),
        MockList(name: "Rooftops", color: .pink, pins: [
            MockPin(name: "Umeda Sky Building", notes: "360° skyline at blue hour", lat: 34.7050, lng: 135.4900, listColor: .pink),
        ]),
    ],
    uncategorized: []
)

private let allProjects: [MockProject] = [tokyoProject, osakaProject]

private let tracks: [MockTrack] = [
    MockTrack(name: "Shinjuku Evening Walk", date: Date().addingTimeInterval(-86400), distanceKm: 4.2, photoCount: 23, durationMin: 67),
    MockTrack(name: "Shibuya Morning Scout", date: Date().addingTimeInterval(-86400 * 2), distanceKm: 2.8, photoCount: 14, durationMin: 41),
    MockTrack(name: "Asakusa Pre-Dawn", date: Date().addingTimeInterval(-86400 * 3), distanceKm: 1.9, photoCount: 31, durationMin: 55),
]

struct MockTrack: Identifiable {
    let id = UUID()
    var name: String
    var date: Date
    var distanceKm: Double
    var photoCount: Int
    var durationMin: Int
}

// MARK: - Root: project picker → in-project tabs

/// Entry point. Shows the project list; once a project is chosen, transitions into the
/// in-project tab shell. The project switcher in the nav bar returns here.
struct iOSAppPreview: View {
    @State private var activeProject: MockProject? = nil

    var body: some View {
        if let project = activeProject {
            iOSInProjectView(project: project, onSwitchProject: { activeProject = nil })
                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
        } else {
            iOSProjectListView(onSelect: { p in
                withAnimation(.easeInOut(duration: 0.28)) { activeProject = p }
            })
            .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)))
        }
    }
}

/// Full-screen project list — same root you'd see before entering a project.
private struct iOSProjectListView: View {
    let onSelect: (MockProject) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(allProjects) { project in
                    Button {
                        onSelect(project)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.body).foregroundStyle(.primary)
                                Text("\(project.lists.count) lists · \(project.allPins.count) locations")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}

// MARK: - In-project shell

/// Once inside a project, this TabView owns everything. All tabs are scoped to `project`.
/// The project is held as mutable state so the sidebar can reorder lists & pins.
struct iOSInProjectView: View {
    let onSwitchProject: () -> Void

    @State private var project: MockProject
    /// Which leaf list IDs are visible on the map. Default: all on.
    @State private var visibleListIDs: Set<UUID>
    @State private var selectedTab = 0
    @State private var showCamera = false
    /// Slide-in sidebar (the hamburger drawer).
    @State private var showSidebar = false
    /// Set when the user taps a pin's mini-map; drives the Map tab camera.
    @State private var mapFocusPin: MockPin? = nil

    init(project: MockProject, onSwitchProject: @escaping () -> Void) {
        self.onSwitchProject = onSwitchProject
        _project = State(initialValue: project)
        _visibleListIDs = State(initialValue: project.allLeafListIDs)
    }

    private func openSidebar() {
        withAnimation(.easeOut(duration: 0.28)) { showSidebar = true }
    }
    private func closeSidebar() {
        withAnimation(.easeIn(duration: 0.24)) { showSidebar = false }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                iOSMapTab(project: project, visibleListIDs: $visibleListIDs, focusPin: $mapFocusPin, onMenu: openSidebar)
                    .tabItem { Label("Map", systemImage: "map.fill") }
                    .tag(0)

                iOSPhotosTab(project: project, onMenu: openSidebar)
                    .tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
                    .tag(1)

                Color.clear
                    .tabItem { Label("Camera", systemImage: "camera.fill") }
                    .tag(2)

                iOSScriptTab(onMenu: openSidebar)
                    .tabItem { Label("Script", systemImage: "doc.text.fill") }
                    .tag(3)

                iOSScoutTab(project: project, onMenu: openSidebar)
                    .tabItem { Label("Scout", systemImage: "figure.walk") }
                    .tag(4)
            }
            .onChange(of: selectedTab) { old, new in
                if new == 2 {
                    selectedTab = old
                    showCamera = true
                }
            }

            // Dimming scrim + sliding drawer
            if showSidebar {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeSidebar() }

                HStack(spacing: 0) {
                    iOSSidebarDrawer(
                        project: $project,
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
        .fullScreenCover(isPresented: $showCamera) {
            CameraSheetPreview(project: project)
        }
    }
}

/// A small reusable hamburger button for each tab's nav bar.
private struct MenuButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "line.3.horizontal").font(.body.weight(.semibold))
        }
    }
}

// MARK: - Map Tab

struct iOSMapTab: View {
    let project: MockProject
    @Binding var visibleListIDs: Set<UUID>
    @Binding var focusPin: MockPin?
    let onMenu: () -> Void
    @State private var selectedPin: MockPin? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapStyleChoice: MapStyleChoice = .standard
    /// false → pin dots, true → photo thumbnails (mirrors the Mac photo/pin toggle).
    @State private var showPhotos = false

    enum MapStyleChoice: String, CaseIterable, Identifiable {
        case standard, satellite, hybrid
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .standard: "map"
            case .satellite: "globe.americas.fill"
            case .hybrid: "map.fill"
            }
        }
        var style: _MapKit_SwiftUI.MapStyle {
            switch self {
            case .standard: .standard
            case .satellite: .imagery
            case .hybrid: .hybrid
            }
        }
    }

    private var visiblePins: [MockPin] {
        project.leafLists
            .filter { visibleListIDs.contains($0.id) }
            .flatMap(\.pins)
    }

    private var defaultRegion: MKCoordinateRegion {
        let center = project.allPins.first.map {
            CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
        } ?? CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                ForEach(visiblePins) { pin in
                    Annotation(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)) {
                        if showPhotos {
                            PhotoMarker(pin: pin)
                                .onTapGesture { selectedPin = pin }
                        } else {
                            PinDot(color: pin.listColor)
                                .onTapGesture { selectedPin = pin }
                        }
                    }
                }
            }
            .mapStyle(mapStyleChoice.style)
            .ignoresSafeArea()
            .onAppear {
                cameraPosition = .region(defaultRegion)
            }
            .onChange(of: focusPin) { _, pin in
                guard let pin else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng),
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    ))
                }
                selectedPin = pin
                focusPin = nil
            }

            HStack(spacing: 8) {
                Button(action: onMenu) {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search locations…").foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                Menu {
                    Picker("Map Type", selection: $mapStyleChoice) {
                        ForEach(MapStyleChoice.allCases) { choice in
                            Label(choice.label, systemImage: choice.icon).tag(choice)
                        }
                    }
                    Picker("Show", selection: $showPhotos) {
                        Label("Pins", systemImage: "mappin").tag(false)
                        Label("Photos", systemImage: "photo").tag(true)
                    }
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .sheet(item: $selectedPin) { pin in
            PinCalloutSheet(pin: pin, project: project)
                .presentationDetents([.height(320), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }
    }
}

private struct PinDot: View {
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 28, height: 28)
            Circle().fill(.white).frame(width: 12, height: 12)
        }
        .shadow(radius: 2)
    }
}

/// Photo-thumbnail map annotation — used when the map is in "Photos" mode.
private struct PhotoMarker: View {
    let pin: MockPin
    var body: some View {
        MockPhoto(pin: pin, width: 120, height: 120)
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white, lineWidth: 2.5)
            }
            .overlay(alignment: .bottom) {
                Circle().fill(pin.listColor).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(y: 5)
            }
            .shadow(radius: 3)
    }
}

private struct PinCalloutSheet: View {
    let pin: MockPin
    let project: MockProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MockPhoto(pin: pin, width: 800, height: 400)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(pin.listColor).frame(width: 10, height: 10)
                    Text(pin.name).font(.headline)
                    Spacer()
                    Button { } label: {
                        Image(systemName: "map").foregroundStyle(.secondary)
                    }
                }

                if !pin.notes.isEmpty {
                    Text(pin.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Divider()

                HStack {
                    Menu {
                        ForEach(project.leafLists) { list in
                            Button { } label: {
                                Label(list.name, systemImage: "mappin.circle")
                            }
                        }
                    } label: {
                        Label("Move to List", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.medium))
                    }
                    Spacer()
                    Button { } label: {
                        Label("Open in Photos", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Photos Tab

/// Photo-centric grid, grouped by list — mirrors the Mac photos grid. The hamburger
/// opens the sidebar; the sidebar is where lists/visibility/drag-reordering live.
struct iOSPhotosTab: View {
    let project: MockProject
    let onMenu: () -> Void

    var body: some View {
        NavigationStack {
            iOSListsGridView(project: project)
                .navigationTitle("Photos")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        MenuButton(action: onMenu)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button { } label: { Label("Import Photos", systemImage: "photo.badge.plus") }
                            Button { } label: { Label("Select", systemImage: "checkmark.circle") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
        }
    }
}

/// Grid mode — photo-centric, grouped by list in the same order as the list view.
private struct iOSListsGridView: View {
    let project: MockProject
    @State private var columns = 3
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(project.leafLists) { list in
                            if !list.pins.isEmpty {
                                Text(list.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.black)

                                iOSMasonryGrid(pins: list.pins, colWidth: colWidth, gap: gap, columns: columns)
                            }
                        }
                    }
                    .padding(.bottom, 60)
                }

                // Column count slider
                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    Slider(
                        value: Binding(
                            get: { Double(9 - columns) },
                            set: { columns = 9 - Int($0.rounded()) }
                        ),
                        in: 1...8, step: 1
                    )
                    .tint(.white.opacity(0.6))
                    Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial.opacity(0.8))
                .clipShape(Capsule())
                .padding(.bottom, 10)
                .frame(maxWidth: 220)
            }
        }
        .background(.black)
        .colorScheme(.dark)
    }
}

// MARK: - Sidebar drawer (hamburger menu)

/// The slide-in sidebar — the iOS equivalent of the Mac app's locations sidebar.
/// Shows the project's lists/folders hierarchy with eye toggles, and supports drag &
/// drop to reorder lists, nest a list into another (creating a folder), reorder photos
/// within a list, and move photos between lists. Top-left returns to the project list.
private struct iOSSidebarDrawer: View {
    @Binding var project: MockProject
    @Binding var visibleListIDs: Set<UUID>
    let onBackToProjects: () -> Void
    let onClose: () -> Void
    let onOpenPinOnMap: (MockPin) -> Void

    @State private var expanded: Set<UUID> = []
    @State private var highlight: DropHighlight? = nil
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionHeader("LISTS")

                    ForEach(project.lists) { list in
                        if list.isFolder {
                            folderRows(list)
                        } else {
                            leafListRow(list, indent: 0, parentVisible: true)
                        }
                    }

                    if !project.uncategorized.isEmpty {
                        sectionHeader("UNCATEGORIZED")
                        ForEach(project.uncategorized) { pin in
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
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: onBackToProjects) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
            }
            Text(project.name)
                .font(.title.bold())
                .lineLimit(2)

            Button { } label: {
                Label("New List", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemFill), in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    @ViewBuilder
    private func folderRows(_ folder: MockList) -> some View {
        let isOpen = expanded.contains(folder.id)
        let folderVisible = visibleListIDs.contains(folder.id)

        DraggableRow(
            dragPayload: "list:\(folder.id)",
            targetID: folder.id,
            kind: .list(canNest: true),
            highlight: $highlight,
            onPerform: { payload, zone in handleDrop(payload, target: folder.id, targetIsList: true, zone: zone) }
        ) {
            HStack(spacing: 8) {
                expandChevron(folder.id, isOpen: isOpen)
                Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary)
                Text(folder.name).font(.body)
                Spacer()
                Text("\(folder.totalPinCount)").font(.caption).foregroundStyle(.secondary)
                eyeButton(folder.id)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }

        if isOpen {
            ForEach(folder.children) { child in
                leafListRow(child, indent: 1, parentVisible: folderVisible)
            }
        }
    }

    @ViewBuilder
    private func leafListRow(_ list: MockList, indent: Int, parentVisible: Bool) -> some View {
        let isOpen = expanded.contains(list.id)
        let visible = parentVisible && visibleListIDs.contains(list.id)

        DraggableRow(
            dragPayload: "list:\(list.id)",
            targetID: list.id,
            kind: .list(canNest: true),
            highlight: $highlight,
            onPerform: { payload, zone in handleDrop(payload, target: list.id, targetIsList: true, zone: zone) }
        ) {
            HStack(spacing: 8) {
                if list.pins.isEmpty {
                    Spacer().frame(width: 16)
                } else {
                    expandChevron(list.id, isOpen: isOpen)
                }
                Circle().fill(list.color).frame(width: 11, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(list.name).font(.body)
                    Text("\(list.pins.count) locations").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                eyeButton(list.id)
            }
            .padding(.leading, 16 + CGFloat(indent) * 18)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .opacity(visible ? 1 : 0.4)
            .contentShape(Rectangle())
        }

        if isOpen {
            ForEach(list.pins) { pin in
                pinRow(pin, indent: indent + 1)
            }
        }
    }

    @ViewBuilder
    private func pinRow(_ pin: MockPin, indent: Int) -> some View {
        DraggableRow(
            dragPayload: "pin:\(pin.id)",
            targetID: pin.id,
            kind: .pin,
            highlight: $highlight,
            onPerform: { payload, zone in handleDrop(payload, target: pin.id, targetIsList: false, zone: zone) }
        ) {
            Button {
                onOpenPinOnMap(pin)
            } label: {
                HStack(spacing: 8) {
                    MockPhoto(pin: pin, width: 90, height: 90)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(pin.name).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                }
                .padding(.leading, 16 + CGFloat(indent) * 18)
                .padding(.trailing, 16)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func expandChevron(_ id: UUID, isOpen: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if isOpen { expanded.remove(id) } else { expanded.insert(id) }
            }
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 16)
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

    // MARK: Drop handling

    private func handleDrop(_ payload: String, target targetID: UUID, targetIsList: Bool, zone: DropZone) {
        let parts = payload.split(separator: ":")
        guard parts.count == 2, let draggedID = UUID(uuidString: String(parts[1])) else { return }
        let isListDrag = (parts[0] == "list")

        withAnimation(.easeInOut(duration: 0.2)) {
            if targetIsList {
                if isListDrag {
                    switch zone {
                    case .into:   project.nestList(draggedID, into: targetID)
                    case .before: project.reorderList(draggedID, near: targetID, after: false)
                    case .after:  project.reorderList(draggedID, near: targetID, after: true)
                    }
                } else {
                    project.movePin(draggedID, intoList: targetID)
                }
            } else if !isListDrag {
                project.reorderPin(draggedID, nearPin: targetID, after: zone == .after)
            }
        }
        // Any newly surfaced leaf lists default to visible.
        visibleListIDs.formUnion(project.allLeafListIDs)
    }
}

// MARK: - List / Pin detail views (unchanged)

struct iOSListDetailView: View {
    fileprivate let list: MockList
    let onOpenPinOnMap: (MockPin) -> Void
    var body: some View {
        List {
            ForEach(list.pins) { pin in
                NavigationLink {
                    iOSPinDetailView(pin: pin, onOpenOnMap: onOpenPinOnMap)
                } label: {
                    PinRow(pin: pin)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    Button { } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .tint(.blue)
                }
            }
            .onMove { _, _ in }
        }
        .navigationTitle(list.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
            Button { } label: { Image(systemName: "plus") }
        }
    }
}

struct iOSPinDetailView: View {
    fileprivate let pin: MockPin
    let onOpenOnMap: (MockPin) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MockPhoto(pin: pin, width: 1000, height: 750)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipped()

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Circle().fill(pin.listColor).frame(width: 12, height: 12)
                        Text(pin.name).font(.title2.bold())
                    }

                    if !pin.notes.isEmpty {
                        Text(pin.notes).font(.body).foregroundStyle(.secondary)
                    }

                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))) {
                        Marker(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng))
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(true)
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            onOpenOnMap(pin)
                        } label: {
                            Label("Open in Map", systemImage: "arrow.up.forward.app")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(8)
                        }
                    }

                    HStack(spacing: 12) {
                        Label(String(format: "%.4f, %.4f", pin.lat, pin.lng), systemImage: "location.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        if let d = pin.dateTaken {
                            Label(d.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(pin.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button { } label: { Image(systemName: "square.and.pencil") }
        }
        .ignoresSafeArea(edges: .top)
    }
}

private struct PinRow: View {
    let pin: MockPin
    var body: some View {
        HStack(spacing: 10) {
            MockPhoto(pin: pin, width: 120, height: 120)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name).font(.body)
                if !pin.notes.isEmpty {
                    Text(pin.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if pin.dateTaken != nil {
                Image(systemName: "photo.fill").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Script Tab

/// Script element types — drives rendering style.
private enum ScriptElement {
    case sceneHeading(String)
    case action(String)
    case character(String)
    case dialogue(String)
    case parenthetical(String)
    case transition(String)
}

/// Mock screenplay excerpt — "The Neon Gardener", Act 1.
private let mockScript: [ScriptElement] = [
    .sceneHeading("INT. DETECTIVE'S OFFICE — NIGHT"),
    .action("Rain hammers the skylight. The office smells of coffee and bad decisions. MARA YUEN (40s, sharp eyes, worn leather jacket) stares at a wall covered in photographs, strings of red thread connecting the faces."),
    .character("MARA"),
    .dialogue("Every city has a pulse. This one stopped three nights ago."),
    .action("She pulls a photograph off the wall. Holds it under the lamp."),
    .character("MARA"),
    .parenthetical("to herself"),
    .dialogue("Who are you?"),

    .sceneHeading("EXT. SHIBUYA CROSSING — CONTINUOUS"),
    .action("The crossing floods with bodies under neon light. Umbrellas bob like a sea of jellyfish. KENJI PARK (30s, rain-soaked, nervous) weaves through the crowd, glancing behind him every few steps."),
    .action("He spots a surveillance camera. Ducks into a doorway. Presses his back against cold tile."),
    .character("KENJI"),
    .parenthetical("into phone, hushed"),
    .dialogue("She's already looking. You said I had more time."),
    .action("A beat. He listens. His face goes still."),
    .character("KENJI"),
    .dialogue("Then I'm already dead."),
    .transition("CUT TO:"),

    .sceneHeading("INT. NOODLE BAR — LATER"),
    .action("Steam rises from a dozen bowls. The place is packed and loud. Mara slides into a booth across from HOSHI (60s, calm, reads people like menus)."),
    .character("HOSHI"),
    .dialogue("You look like you haven't slept."),
    .character("MARA"),
    .dialogue("I look like I haven't slept in three years. Tonight's new."),
    .action("Hoshi sets down two cups of tea. Doesn't ask."),
    .character("HOSHI"),
    .dialogue("The man in the photograph — Kenji Park. He worked for the garden project. Underground hydroponics. Funded by people who don't like questions."),
    .character("MARA"),
    .dialogue("What kind of people?"),
    .character("HOSHI"),
    .parenthetical("long pause"),
    .dialogue("The kind who plant things and wait."),
    .action("Mara wraps both hands around her cup. Outside, rain streaks the glass. A shadow passes."),

    .sceneHeading("EXT. SIDE STREET — NIGHT"),
    .action("Mara steps out of the noodle bar. Looks both ways. The street is empty — then isn't."),
    .action("A figure in a grey coat stands at the far end, perfectly still under a flickering lamp. They hold an umbrella open in one hand. In the other: a single white flower."),
    .action("They turn. Walk away. Unhurried."),
    .character("MARA"),
    .parenthetical("under her breath"),
    .dialogue("There you are."),
    .transition("FADE OUT."),
]

struct iOSScriptTab: View {
    let onMenu: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(mockScript.enumerated()), id: \.offset) { _, element in
                        ScriptElementView(element: element)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color(.systemBackground))
            .navigationTitle("The Neon Gardener")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    MenuButton(action: onMenu)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { } label: { Image(systemName: "textformat.size") }
                }
            }
        }
    }
}

private struct ScriptElementView: View {
    let element: ScriptElement

    var body: some View {
        switch element {
        case .sceneHeading(let text):
            // Bold pill-style scene heading — easy to scan while scrolling
            Text(text)
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .tracking(0.5)
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 28)
                .padding(.bottom, 12)

        case .action(let text):
            Text(text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary)
                .lineSpacing(5)
                .padding(.bottom, 14)

        case .character(let text):
            Text(text)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)
                .padding(.bottom, 2)

        case .dialogue(let text):
            Text(text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(.primary)
                .lineSpacing(4)
                .padding(.leading, 28)
                .padding(.trailing, 16)
                .padding(.bottom, 10)

        case .parenthetical(let text):
            Text("(\(text))")
                .font(.system(.subheadline, design: .serif).italic())
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
                .padding(.bottom, 2)

        case .transition(let text):
            Text(text)
                .font(.system(.footnote, design: .monospaced).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 16)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - Scout Tab

struct iOSScoutTab: View {
    let project: MockProject
    let onMenu: () -> Void
    @State private var isRecording = false

    var body: some View {
        NavigationStack {
            if isRecording {
                iOSRecordingView(isRecording: $isRecording)
            } else {
                iOSScoutIdleView(project: project, isRecording: $isRecording, onMenu: onMenu)
            }
        }
    }
}

private struct iOSScoutIdleView: View {
    let project: MockProject
    @Binding var isRecording: Bool
    let onMenu: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Button { isRecording = true } label: {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 110, height: 110)
                                .shadow(color: .orange.opacity(0.4), radius: 16, y: 4)
                            VStack(spacing: 4) {
                                Image(systemName: "figure.walk").font(.system(size: 30, weight: .semibold))
                                Text("Scout").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    Text("Start recording your scouting trip")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recording to")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.orange)
                        Text(project.name).font(.body)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Trips")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
                    ForEach(tracks) { track in TrackRow(track: track) }
                }
            }
        }
        .navigationTitle("Scout")
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                MenuButton(action: onMenu)
            }
        }
    }
}

private struct TrackRow: View {
    let track: MockTrack
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: "figure.walk").foregroundStyle(.orange).font(.body.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.body)
                HStack(spacing: 8) {
                    Label(String(format: "%.1f km", track.distanceKm), systemImage: "location")
                    Label("\(track.durationMin) min", systemImage: "clock")
                    Label("\(track.photoCount) photos", systemImage: "camera")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(track.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}

private struct iOSRecordingView: View {
    @Binding var isRecording: Bool
    @State private var elapsed: TimeInterval = 1847
    @State private var showCamera = false
    private let tokyoRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6940, longitude: 139.7020),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    var body: some View {
        ZStack {
            Map(initialPosition: .region(tokyoRegion)) {
                ForEach(tokyoProject.lists[0].pins) { pin in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                    }
                }
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: 35.6940, longitude: 139.7032)) {
                    ZStack {
                        Circle().fill(.white).frame(width: 20, height: 20)
                        Circle().fill(.blue).frame(width: 14, height: 14)
                        Circle().stroke(.blue.opacity(0.3), lineWidth: 1).frame(width: 36, height: 36)
                    }
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack(spacing: 0) {
                    StatChip(value: formatTime(elapsed), label: "elapsed", icon: "clock.fill")
                    Divider().frame(height: 30)
                    StatChip(value: "2.4 km", label: "distance", icon: "location.fill")
                    Divider().frame(height: 30)
                    StatChip(value: "7", label: "photos", icon: "camera.fill")
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16).padding(.top, 8)

                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording — Tokyo Golden Gai Area").font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                HStack(spacing: 24) {
                    Button { isRecording = false } label: {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 60, height: 60)
                            RoundedRectangle(cornerRadius: 4).fill(.red).frame(width: 22, height: 22)
                        }
                    }
                    Button { showCamera = true } label: {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 80, height: 80)
                                .shadow(color: .orange.opacity(0.5), radius: 12)
                            Image(systemName: "camera.fill").font(.title2.weight(.semibold)).foregroundStyle(.white)
                        }
                    }
                    Button { } label: {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 60, height: 60)
                            Image(systemName: "location.fill").foregroundStyle(.blue).font(.title3)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("").navigationBarHidden(true)
        .fullScreenCover(isPresented: $showCamera) {
            CameraSheetPreview(project: tokyoProject)
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60; let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct StatChip: View {
    let value: String; let label: String; let icon: String
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
    }
}

// MARK: - Photo grid helpers

private struct iOSMasonryGrid: View {
    let pins: [MockPin]; let colWidth: CGFloat; let gap: CGFloat; let columns: Int
    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: gap) {
                    ForEach(pins.indices.filter { $0 % columns == col }, id: \.self) { idx in
                        PhotoCell(pin: pins[idx], width: colWidth)
                    }
                }
            }
        }
    }
}

private struct PhotoCell: View {
    let pin: MockPin; let width: CGFloat
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MockPhoto(pin: pin, width: 400, height: 300)
                .frame(width: width, height: width * 0.75)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 36)
        }
        .frame(width: width).clipped()
    }
}

// MARK: - Camera sheet

private struct CameraSheetPreview: View {
    let project: MockProject
    @Environment(\.dismiss) private var dismiss
    private let lenses: [CameraLens] = [
        CameraLens(zoom: 0.5, label: ".5"),
        CameraLens(zoom: 1, label: "1"),
        CameraLens(zoom: 2, label: "2"),
        CameraLens(zoom: 3, label: "3"),
    ]
    @State private var selectedZoom: Double = 1
    @State private var flashOn = false
    @State private var targetListID: UUID?

    init(project: MockProject) {
        self.project = project
        _targetListID = State(initialValue: project.leafLists.first?.id)
    }

    private var targetListName: String {
        project.leafLists.first { $0.id == targetListID }?.name ?? "Uncategorized"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Rectangle()
                .fill(LinearGradient(colors: [Color(white: 0.08), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 72)).foregroundStyle(.white.opacity(0.12))
                        Text("Live viewfinder").font(.caption2).foregroundStyle(.white.opacity(0.18))
                    }
                }

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.white).frame(width: 44, height: 44)
                    }
                    Spacer()
                    Button { flashOn.toggle() } label: {
                        Image(systemName: flashOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.headline)
                            .foregroundStyle(flashOn ? .yellow : .white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 8).padding(.top, 12)

                Spacer()

                HStack(spacing: 6) {
                    ForEach(lenses) { lens in
                        let isSel = lens.zoom == selectedZoom
                        Button {
                            withAnimation(.snappy(duration: 0.18)) { selectedZoom = lens.zoom }
                        } label: {
                            Text(isSel ? "\(lens.label)×" : lens.label)
                                .font(.system(size: isSel ? 13 : 12, weight: .semibold))
                                .foregroundStyle(isSel ? .yellow : .white)
                                .frame(width: isSel ? 46 : 36, height: isSel ? 46 : 36)
                                .background(Circle().fill(.black.opacity(0.45)))
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(.bottom, 16)

                Menu {
                    Button { targetListID = nil } label: {
                        Label("Uncategorized", systemImage: targetListID == nil ? "checkmark" : "tray")
                    }
                    ForEach(project.leafLists) { list in
                        Button { targetListID = list.id } label: {
                            Label(list.name, systemImage: targetListID == list.id ? "checkmark" : "mappin.circle")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                        Text("Adding to: \(targetListName)")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.15)))
                }
                .padding(.bottom, 20)

                HStack {
                    Spacer()
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 78, height: 78)
                        Circle().fill(.white).frame(width: 66, height: 66)
                    }
                    Spacer()
                }
                .padding(.horizontal, 50).padding(.bottom, 44)
            }
        }
    }
}

private struct CameraLens: Identifiable, Equatable {
    let id = UUID()
    let zoom: Double
    let label: String
}

// MARK: - Previews

#Preview("Full App") {
    iOSAppPreview()
}

#Preview("Project List") {
    iOSProjectListView(onSelect: { _ in })
}

#Preview("In Project") {
    iOSInProjectView(project: tokyoProject, onSwitchProject: { })
}

#Preview("Map Tab") {
    iOSMapTab(project: tokyoProject, visibleListIDs: .constant(tokyoProject.allLeafListIDs), focusPin: .constant(nil), onMenu: { })
}

#Preview("Photos Tab") {
    iOSPhotosTab(project: tokyoProject, onMenu: { })
}

#Preview("Sidebar Drawer") {
    iOSSidebarDrawer(
        project: .constant(tokyoProject),
        visibleListIDs: .constant(tokyoProject.allLeafListIDs),
        onBackToProjects: { }, onClose: { }, onOpenPinOnMap: { _ in }
    )
}

#Preview("Script Tab") {
    iOSScriptTab(onMenu: { })
}

#Preview("List Detail") {
    NavigationStack {
        iOSListDetailView(list: tokyoProject.lists[1], onOpenPinOnMap: { _ in })
    }
}

#Preview("Pin Detail") {
    NavigationStack {
        iOSPinDetailView(pin: tokyoProject.lists[0].pins[0], onOpenOnMap: { _ in })
    }
}

#Preview("Scout — Idle") {
    iOSScoutTab(project: tokyoProject, onMenu: { })
}

#Preview("Scout — Recording") {
    NavigationStack {
        iOSRecordingView(isRecording: .constant(true))
    }
}

#Preview("In-Trip Camera") {
    CameraSheetPreview(project: tokyoProject)
}
#endif
