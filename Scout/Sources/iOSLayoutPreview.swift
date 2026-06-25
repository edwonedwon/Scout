// iOSLayoutPreview.swift
// Standalone UI mockup of the proposed iOS Scout app layout.
// Uses 100% fake data — no SwiftData, no live services.
// Open any #Preview below in Xcode to explore the proposed UI.

#if os(iOS) && DEBUG
import SwiftUI
import MapKit

// MARK: - Mock data

private struct MockPin: Identifiable {
    let id = UUID()
    var name: String
    var notes: String
    var lat: Double
    var lng: Double
    var imageName: String?
    var listColor: Color
    var dateTaken: Date?
}

private struct MockList: Identifiable {
    let id = UUID()
    var name: String
    var color: Color
    var pins: [MockPin]
    /// Child lists — when non-empty this list renders as a folder (folder icon, indented kids).
    var children: [MockList] = []

    var isFolder: Bool { !children.isEmpty }
    /// Pin count including all child lists (matches the Mac folder count badge).
    var totalPinCount: Int { pins.count + children.reduce(0) { $0 + $1.pins.count } }
    /// Leaf lists that actually hold pins: self when not a folder, else the children.
    var leafLists: [MockList] { isFolder ? children : [self] }
}

private extension MockProject {
    /// All photo-bearing lists, flattening folders into their child lists.
    var leafLists: [MockList] { lists.flatMap(\.leafLists) }
    /// Every pin in the project (across lists, folders, and uncategorized).
    var allPins: [MockPin] { leafLists.flatMap(\.pins) + uncategorized }
}

private struct MockProject: Identifiable {
    let id = UUID()
    var name: String
    var lists: [MockList]
    var uncategorized: [MockPin]
}

private struct MockTrack: Identifiable {
    let id = UUID()
    var name: String
    var date: Date
    var distanceKm: Double
    var photoCount: Int
    var durationMin: Int
}

// Tokyo scouting project
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
        // A folder: a list that holds other lists (matches the Mac folder feature).
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

// A second project so the Projects tab can show a real project-list root.
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

// MARK: - Root: iOS app tab structure

struct iOSAppPreview: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            iOSMapTab()
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(0)

            iOSProjectsTab()
                .tabItem { Label("Projects", systemImage: "folder.fill") }
                .tag(1)

            iOSPhotosTab()
                .tabItem { Label("Photos", systemImage: "photo.on.rectangle.angled") }
                .tag(2)

            iOSScoutTab()
                .tabItem { Label("Scout", systemImage: "figure.walk") }
                .tag(3)
        }
    }
}

// MARK: - Map Tab

struct iOSMapTab: View {
    @State private var selectedPin: MockPin? = nil
    @State private var sheetHeight: PresentationDetent = .medium
    private let tokyoRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917),
        span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
    )

    var body: some View {
        ZStack(alignment: .top) {
            Map(initialPosition: .region(tokyoRegion)) {
                ForEach(tokyoProject.allPins) { pin in
                    Annotation(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)) {
                        PinDot(color: pin.listColor)
                            .onTapGesture { selectedPin = pin }
                    }
                }
            }
            .ignoresSafeArea()

            // Search bar overlay
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Search locations…")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .sheet(item: $selectedPin) { pin in
            PinCalloutSheet(pin: pin)
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

private struct PinCalloutSheet: View {
    let pin: MockPin
    @State private var selectedList = 0
    private let lists = tokyoProject.lists

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Photo strip
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray5))
                .frame(height: 130)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(pin.listColor).frame(width: 10, height: 10)
                    Text(pin.name).font(.headline)
                    Spacer()
                    Button { } label: {
                        Image(systemName: "map")
                            .foregroundStyle(.secondary)
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
                        ForEach(lists) { list in
                            Button {
                            } label: {
                                Label(list.name, systemImage: "mappin.circle")
                            }
                        }
                    } label: {
                        Label("Move to List", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.medium))
                    }
                    Spacer()
                    Button {
                    } label: {
                        Label("Open in Photos", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Projects Tab

/// Projects tab root: a list of all projects → tap into a project's lists/folders.
struct iOSProjectsTab: View {
    var body: some View {
        NavigationStack {
            List {
                ForEach(allProjects) { project in
                    NavigationLink {
                        iOSProjectDetailView(project: project)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name).font(.body)
                                Text("\(project.lists.count) lists")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
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

/// A single project's lists (with folders) + uncategorized photos. Mirrors the Mac sidebar:
/// eye toggles for visibility, folders that expand to show child lists, a folder acting as a
/// master visibility gate over its children.
struct iOSProjectDetailView: View {
    let project: MockProject
    // Visibility set (eye on). A list is effectively visible only if it AND its ancestors are on.
    @State private var visible: Set<UUID> = []
    @State private var expanded: Set<UUID> = []
    @State private var search = ""

    var body: some View {
        List {
            ForEach(project.lists) { list in
                if list.isFolder {
                    folderRows(list)
                } else {
                    listRow(list, indent: 0, gatedOff: false)
                }
            }

            if !project.uncategorized.isEmpty {
                Section("Uncategorized") {
                    ForEach(project.uncategorized) { pin in
                        NavigationLink { iOSPinDetailView(pin: pin) } label: { PinRow(pin: pin) }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search photos")
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { } label: { Label("New List", systemImage: "plus") }
                    Button { } label: { Label("Import Photos", systemImage: "photo.badge.plus") }
                } label: { Image(systemName: "plus") }
            }
        }
    }

    @ViewBuilder
    private func folderRows(_ folder: MockList) -> some View {
        let isOpen = expanded.contains(folder.id)
        let folderOff = !visible.contains(folder.id)
        // Folder header row
        HStack(spacing: 10) {
            Button {
                if isOpen { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
            } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 16)
            }
            .buttonStyle(.plain)
            Image(systemName: isOpen ? "folder.fill" : "folder").foregroundStyle(.secondary)
            Text(folder.name).font(.body)
            Spacer()
            Text("\(folder.totalPinCount)").font(.caption).foregroundStyle(.secondary)
            eyeButton(folder.id)
        }
        .padding(.vertical, 2)

        if isOpen {
            ForEach(folder.children) { child in
                listRow(child, indent: 1, gatedOff: folderOff)
            }
        }
    }

    @ViewBuilder
    private func listRow(_ list: MockList, indent: Int, gatedOff: Bool) -> some View {
        let off = gatedOff || !visible.contains(list.id)
        NavigationLink {
            iOSListDetailView(list: list)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(list.color).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name).font(.body)
                    Text("\(list.pins.count) locations").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                eyeButton(list.id)
            }
            .padding(.leading, CGFloat(indent) * 18)
            .padding(.vertical, 2)
            .opacity(off ? 0.45 : 1)
        }
    }

    private func eyeButton(_ id: UUID) -> some View {
        Button {
            if visible.contains(id) { visible.remove(id) } else { visible.insert(id) }
        } label: {
            Image(systemName: visible.contains(id) ? "eye.fill" : "eye")
                .foregroundStyle(visible.contains(id) ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }
}

struct iOSListDetailView: View {
    let list: MockList
    var body: some View {
        List {
            ForEach(list.pins) { pin in
                NavigationLink {
                    iOSPinDetailView(pin: pin)
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
    let pin: MockPin
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Photo
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color(.systemGray5))
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            if pin.dateTaken != nil {
                                Text("Tap to open")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Circle().fill(pin.listColor).frame(width: 12, height: 12)
                        Text(pin.name).font(.title2.bold())
                    }

                    if !pin.notes.isEmpty {
                        Text(pin.notes)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    // Mini map
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng),
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))) {
                        Marker(pin.name, coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng))
                    }
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(true)

                    HStack(spacing: 12) {
                        Label(String(format: "%.4f, %.4f", pin.lat, pin.lng), systemImage: "location.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let d = pin.dateTaken {
                            Label(d.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemGray5))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.name).font(.body)
                if !pin.notes.isEmpty {
                    Text(pin.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if pin.dateTaken != nil {
                Image(systemName: "photo.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Photos Tab

struct iOSPhotosTab: View {
    @State private var columns = 3
    private let gap: CGFloat = 2
    private let allPins = tokyoProject.leafLists.flatMap(\.pins)

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let colWidth = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tokyoProject.leafLists) { list in
                                if !list.pins.isEmpty {
                                    // Section header
                                    Text(list.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.black)

                                    // Masonry grid (simplified 3-column)
                                    iOSMasonryGrid(pins: list.pins, colWidth: colWidth, gap: gap, columns: columns)
                                }
                            }
                        }
                        .padding(.bottom, 52)
                    }

                    // Size slider
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
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private struct iOSMasonryGrid: View {
    let pins: [MockPin]
    let colWidth: CGFloat
    let gap: CGFloat
    let columns: Int

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
    let pin: MockPin
    let width: CGFloat
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 0)
                .fill(pin.listColor.opacity(0.3))
                .frame(width: width, height: width * 0.75)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.3))
                }

            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 36)
        }
        .frame(width: width)
        .clipped()
    }
}

// MARK: - Scout Tab

struct iOSScoutTab: View {
    @State private var isRecording = false

    var body: some View {
        NavigationStack {
            if isRecording {
                iOSRecordingView(isRecording: $isRecording)
            } else {
                iOSScoutIdleView(isRecording: $isRecording)
            }
        }
    }
}

private struct iOSScoutIdleView: View {
    @Binding var isRecording: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Start button
                VStack(spacing: 14) {
                    Button {
                        isRecording = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.orange, .red],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 110, height: 110)
                                .shadow(color: .orange.opacity(0.4), radius: 16, y: 4)

                            VStack(spacing: 4) {
                                Image(systemName: "figure.walk")
                                    .font(.system(size: 30, weight: .semibold))
                                Text("Scout")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.white)
                        }
                    }
                    Text("Start recording your scouting trip")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                // Project picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recording to")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.orange)
                        Text(tokyoProject.name)
                            .font(.body)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                }

                // Past trips
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent Trips")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)

                    ForEach(tracks) { track in
                        TrackRow(track: track)
                    }
                }
            }
        }
        .navigationTitle("Scout")
        .background(Color(.systemGroupedBackground))
    }
}

private struct TrackRow: View {
    let track: MockTrack

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: "figure.walk")
                    .foregroundStyle(.orange)
                    .font(.body.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.body)
                HStack(spacing: 8) {
                    Label(String(format: "%.1f km", track.distanceKm), systemImage: "location")
                    Label("\(track.durationMin) min", systemImage: "clock")
                    Label("\(track.photoCount) photos", systemImage: "camera")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Text(track.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }
}

private struct iOSRecordingView: View {
    @Binding var isRecording: Bool
    @State private var elapsed: TimeInterval = 1847  // mock: 30 min in
    @State private var showCamera = false
    private let tokyoRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6940, longitude: 139.7020),
        span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
    )

    var body: some View {
        ZStack {
            // Full-screen live map
            Map(initialPosition: .region(tokyoRegion)) {
                // Mock trail pins
                ForEach(tokyoProject.lists[0].pins) { pin in
                    Annotation("", coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lng)) {
                        Circle().fill(.orange).frame(width: 8, height: 8)
                    }
                }
                // Current position
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
                // Stats bar
                HStack(spacing: 0) {
                    StatChip(value: formatTime(elapsed), label: "elapsed", icon: "clock.fill")
                    Divider().frame(height: 30)
                    StatChip(value: "2.4 km", label: "distance", icon: "location.fill")
                    Divider().frame(height: 30)
                    StatChip(value: "7", label: "photos", icon: "camera.fill")
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Recording indicator
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording — Tokyo Golden Gai Area")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

                Spacer()

                // Bottom controls
                HStack(spacing: 24) {
                    Button {
                        isRecording = false
                    } label: {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 60, height: 60)
                            RoundedRectangle(cornerRadius: 4).fill(.red).frame(width: 22, height: 22)
                        }
                    }

                    Button {
                        showCamera = true
                    } label: {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 80, height: 80)
                                .shadow(color: .orange.opacity(0.5), radius: 12)
                            Image(systemName: "camera.fill")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }

                    Button { } label: {
                        ZStack {
                            Circle().fill(.ultraThinMaterial).frame(width: 60, height: 60)
                            Image(systemName: "location.fill")
                                .foregroundStyle(.blue)
                                .font(.title3)
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("")
        .navigationBarHidden(true)
        .sheet(isPresented: $showCamera) {
            CameraSheetPreview()
                .presentationDetents([.large])
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct StatChip: View {
    let value: String
    let label: String
    let icon: String
    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private struct CameraSheetPreview: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 0)
                    .fill(Color(.systemGray6).opacity(0.15))
                    .frame(maxWidth: .infinity)
                    .frame(height: 400)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 60))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("Live camera preview")
                                .foregroundStyle(.white.opacity(0.5))
                                .font(.caption)
                            Text("Photo will be added to\nTokyo — Spring 2026")
                                .foregroundStyle(.white.opacity(0.4))
                                .font(.caption2)
                                .multilineTextAlignment(.center)
                        }
                    }
                Spacer()
                HStack(spacing: 50) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    // Shutter button
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 70, height: 70)
                        Circle().fill(.white).frame(width: 58, height: 58)
                    }
                    Button { } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - Previews

#Preview("Full App", traits: .sizeThatFitsLayout) {
    iOSAppPreview()
}

#Preview("Map Tab") {
    iOSMapTab()
}

#Preview("Map — Pin Selected") {
    PinCalloutSheet(pin: tokyoProject.lists[0].pins[0])
        .presentationDetents([.height(320)])
}

#Preview("Projects Tab") {
    iOSProjectsTab()
}

#Preview("List Detail") {
    NavigationStack {
        iOSListDetailView(list: tokyoProject.lists[1])
    }
}

#Preview("Pin Detail") {
    NavigationStack {
        iOSPinDetailView(pin: tokyoProject.lists[0].pins[0])
    }
}

#Preview("Photos Tab") {
    iOSPhotosTab()
}

#Preview("Scout — Idle") {
    iOSScoutTab()
}

#Preview("Scout — Recording") {
    NavigationStack {
        iOSRecordingView(isRecording: .constant(true))
    }
}

#Preview("In-Trip Camera") {
    CameraSheetPreview()
}
#endif
