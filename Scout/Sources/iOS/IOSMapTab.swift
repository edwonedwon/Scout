// IOSMapTab.swift — native SwiftUI map for iOS, wired to real pins.

#if os(iOS)
import SwiftUI
import MapKit
import ScoutKit

struct IOSMapTab: View {
    @ObservedObject var project: ProjectVM
    @Binding var visibleListIDs: Set<UUID>
    @Binding var focusPin: PinVM?
    let onMenu: () -> Void

    @State private var selectedPin: PinVM?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mapStyleChoice: MapStyleChoice = .standard
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

    private var visiblePins: [PinVM] {
        project.visiblePins(visibleListIDs).filter { $0.latitude != 0 || $0.longitude != 0 }
    }

    private var defaultRegion: MKCoordinateRegion {
        let center = project.allMapPins.first.map(\.coordinate)
            ?? CLLocationCoordinate2D(latitude: 35.6895, longitude: 139.6917)
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $cameraPosition) {
                ForEach(visiblePins, id: \.uuid) { pin in
                    Annotation(pin.name, coordinate: pin.coordinate) {
                        Group {
                            if showPhotos {
                                IOSPhotoMarker(pin: pin)
                            } else {
                                IOSPinDot(color: pin.displayColor)
                            }
                        }
                        .onTapGesture { selectedPin = pin }
                    }
                }
            }
            .mapStyle(mapStyleChoice.style)
            .ignoresSafeArea()
            .onAppear { cameraPosition = .region(defaultRegion) }
            .onChange(of: focusPin) { _, pin in
                guard let pin else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: pin.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    ))
                }
                selectedPin = pin
                focusPin = nil
            }

            HStack(spacing: 8) {
                Button(action: onMenu) {
                    Image(systemName: "line.3.horizontal")
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(width: 36, height: 36).background(.regularMaterial, in: Circle())
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search locations…").foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
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
                        .font(.body.weight(.semibold)).foregroundStyle(.primary)
                        .frame(width: 36, height: 36).background(.regularMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 12).padding(.top, 8)
        }
        .sheet(item: $selectedPin) { pin in
            IOSPinCalloutSheet(pin: pin)
                .presentationDetents([.height(320), .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
        }
    }
}

struct IOSPinDot: View {
    let color: Color
    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: 28, height: 28)
            Circle().fill(.white).frame(width: 12, height: 12)
        }
        .shadow(radius: 2)
    }
}

struct IOSPhotoMarker: View {
    let pin: PinVM
    var body: some View {
        IOSPinThumb(pin: pin, targetPixelSize: 96, cornerRadius: 8)
            .frame(width: 48, height: 48)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2.5) }
            .overlay(alignment: .bottom) {
                Circle().fill(pin.displayColor).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5)).offset(y: 5)
            }
            .shadow(radius: 3)
    }
}

struct IOSPinCalloutSheet: View {
    @ObservedObject var pin: PinVM

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSPinThumb(pin: pin, targetPixelSize: 256, cornerRadius: 10)
                .frame(height: 130).frame(maxWidth: .infinity)
                .padding(.horizontal, 16).padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle().fill(pin.displayColor).frame(width: 10, height: 10)
                    Text(pin.name).font(.headline)
                    Spacer()
                }
                if !pin.notes.isEmpty {
                    Text(pin.notes).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Divider()
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
}
#endif
