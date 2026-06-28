// IOSContentTabs.swift — Photos, Script, Scout tabs + Pin detail + Camera stub.

#if os(iOS)
import SwiftUI
import MapKit
import ScoutKit

// MARK: - Photos Tab

struct IOSPhotosTab: View {
    @ObservedObject var project: ProjectVM
    let onMenu: () -> Void

    /// (list, pins) sections in display order — folders expand to their child lists.
    private var sections: [(list: ListVM, pins: [PinVM])] {
        var out: [(ListVM, [PinVM])] = []
        for list in project.topLevelLists {
            if list.isFolder {
                for child in list.iosSortedChildren where !child.livePins.isEmpty {
                    out.append((child, child.sortedPins))
                }
                if !list.livePins.isEmpty { out.append((list, list.sortedPins)) }
            } else if !list.livePins.isEmpty {
                out.append((list, list.sortedPins))
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if sections.isEmpty {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                           description: Text("Photos you add to lists appear here."))
                } else {
                    IOSMasonryGridView(sections: sections)
                }
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { IOSMenuButton(action: onMenu) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { } label: { Label("Import Photos", systemImage: "photo.badge.plus") } // TODO M3
                        Button { } label: { Label("Select", systemImage: "checkmark.circle") }         // TODO M2
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }
}

private struct IOSMasonryGridView: View {
    let sections: [(list: ListVM, pins: [PinVM])]
    @State private var columns = 3
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections, id: \.list.uuid) { section in
                            Text(section.list.name)
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black)
                            masonry(section.pins, colWidth: colWidth)
                        }
                    }
                    .padding(.bottom, 60)
                }

                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    Slider(
                        value: Binding(get: { Double(9 - columns) }, set: { columns = 9 - Int($0.rounded()) }),
                        in: 1...8, step: 1
                    )
                    .tint(.white.opacity(0.6))
                    Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.ultraThinMaterial.opacity(0.8)).clipShape(Capsule())
                .padding(.bottom, 10).frame(maxWidth: 220)
            }
        }
        .background(.black)
        .colorScheme(.dark)
    }

    private func masonry(_ pins: [PinVM], colWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gap) {
            ForEach(0..<columns, id: \.self) { col in
                LazyVStack(spacing: gap) {
                    ForEach(pins.indices.filter { $0 % columns == col }, id: \.self) { idx in
                        NavigationLink {
                            IOSPinDetailView(pin: pins[idx])
                        } label: {
                            IOSPhotoCell(pin: pins[idx], width: colWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct IOSPhotoCell: View {
    @ObservedObject var pin: PinVM
    let width: CGFloat
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            IOSPinThumb(pin: pin, targetPixelSize: width * UIScreen.main.scale)
                .frame(width: width, height: width * 0.75).clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .frame(height: 36)
        }
        .frame(width: width).clipped()
    }
}

// MARK: - Pin detail

struct IOSPinDetailView: View {
    @ObservedObject var pin: PinVM
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IOSPinThumb(pin: pin, targetPixelSize: UIScreen.main.bounds.width * UIScreen.main.scale)
                    .frame(maxWidth: .infinity).frame(height: 260).clipped()

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Circle().fill(pin.displayColor).frame(width: 12, height: 12)
                        Text(pin.name).font(.title2.bold())
                    }
                    if !pin.notes.isEmpty {
                        Text(pin.notes).font(.body).foregroundStyle(.secondary)
                    }
                    Map(initialPosition: .region(MKCoordinateRegion(
                        center: pin.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    ))) {
                        Marker(pin.name, coordinate: pin.coordinate)
                    }
                    .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 12)).disabled(true)

                    HStack(spacing: 12) {
                        Label(String(format: "%.4f, %.4f", pin.latitude, pin.longitude), systemImage: "location.fill")
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
        .ignoresSafeArea(edges: .top)
    }
}

// MARK: - Script Tab

struct IOSScriptTab: View {
    @ObservedObject var project: ProjectVM
    let onMenu: () -> Void

    private var script: ScriptVM? { project.scripts.first }
    private var elements: [FountainElement] {
        script.map { FountainParser.parse($0.rawText) } ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if let script {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(elements.enumerated()), id: \.offset) { _, element in
                                IOSScriptElementView(element: element)
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 24)
                    }
                    .background(Color(.systemBackground))
                    .navigationTitle(script.name)
                } else {
                    ContentUnavailableView("No Script", systemImage: "doc.text",
                                           description: Text("Import a .fountain script on the Mac to see it here."))
                        .navigationTitle("Script")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { IOSMenuButton(action: onMenu) }
            }
        }
    }
}

private struct IOSScriptElementView: View {
    let element: FountainElement
    var body: some View {
        switch element.type {
        case .sceneHeading:
            Text(element.text)
                .font(.system(.footnote, design: .monospaced).weight(.bold)).tracking(0.5)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 28).padding(.bottom, 12)
        case .character:
            Text(element.text)
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .foregroundStyle(Color.accentColor).padding(.top, 4).padding(.bottom, 2)
        case .dialogue:
            Text(element.text)
                .font(.system(.body, design: .serif)).lineSpacing(4)
                .padding(.leading, 28).padding(.trailing, 16).padding(.bottom, 10)
        case .parenthetical:
            Text(element.text)
                .font(.system(.subheadline, design: .serif).italic()).foregroundStyle(.secondary)
                .padding(.leading, 28).padding(.bottom, 2)
        case .transition:
            Text(element.text)
                .font(.system(.footnote, design: .monospaced).weight(.medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 16).padding(.bottom, 8)
        case .section:
            Text(element.text).font(.title3.bold()).padding(.top, 20).padding(.bottom, 8)
        case .synopsis:
            Text(element.text).font(.subheadline.italic()).foregroundStyle(.secondary).padding(.bottom, 8)
        case .centered:
            Text(element.text).font(.system(.body, design: .serif))
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
        case .pageBreak:
            Divider().padding(.vertical, 16)
        case .blank, .titlePage:
            EmptyView()
        case .action:
            Text(element.text).font(.system(.body, design: .serif)).lineSpacing(5).padding(.bottom, 14)
        }
    }
}

// MARK: - Scout Tab (idle stub; recording deferred to M4)

struct IOSScoutTab: View {
    @ObservedObject var project: ProjectVM
    let onMenu: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Button { } label: {  // TODO M4: start CLLocationManager recording
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
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 16)
                    }

                    ContentUnavailableView("No Trips Yet", systemImage: "map",
                                           description: Text("Recorded scouting trips will appear here."))
                        .frame(height: 200)
                }
            }
            .navigationTitle("Scout")
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { IOSMenuButton(action: onMenu) }
            }
        }
    }
}

// MARK: - Camera sheet (stub; capture deferred to M3)

struct IOSCameraSheet: View {
    @ObservedObject var project: ProjectVM
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "camera.viewfinder").font(.system(size: 72)).foregroundStyle(.white.opacity(0.15))
                Text("Camera capture coming soon").font(.caption).foregroundStyle(.white.opacity(0.3))
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 12)
                Spacer()
                ZStack {
                    Circle().stroke(.white, lineWidth: 3).frame(width: 78, height: 78)
                    Circle().fill(.white).frame(width: 66, height: 66)
                }
                .padding(.bottom, 44)
            }
        }
    }
}
#endif
