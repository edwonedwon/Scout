import SwiftUI
import MapKit
import ScoutKit

// Map, search, regions, boundaries, view-mode toggle.
extension ContentView {
    var scoutMap: some View {
        ScoutMapView(
            selection: $selectedLocation,
            multiSelection: selection,
            locations: locations,
            projectPins: cachedProjectPins,
            projectPinsVersion: pinCacheVersion,
            scrollToZoom: scrollToZoom,
            initialRegion: initialRegion,
            controller: mapController,
            onRegionEnd: { region in
                savedLat      = region.center.latitude
                savedLng      = region.center.longitude
                savedLatDelta = region.span.latitudeDelta
                savedLngDelta = region.span.longitudeDelta
            },
            isDrawingMode: searchArea.isDrawing,
            searchPolygon: searchArea.polygon,
            onPolygonComplete: { coords in searchArea.setPolygon(coords) },
            onFrameAllPins: frameAllProjectPins,
            onPinDoubleClicked: { loc in
                // Saved pin → reuse the full grid-ordered carousel; otherwise (search
                // result) open the carousel with just this location's photos.
                if let pin = pin(byUUID: loc.id) {
                    openInCarousel(pin)
                } else if !loc.images.isEmpty {
                    let imgs = loc.fullResImages.isEmpty ? loc.images : loc.fullResImages
                    PhotoViewerState.shared.show(images: imgs, startingAt: 0, location: loc)
                }
            },
            mapType: mapStyle.mapType,
            cyclingProvider: cyclingProvider,
            showPhotoAnnotations: showPhotoAnnotations,
            pinScale: pinSize,
            availableLists: openProjectLists,
            onSaveToList: saveToList,
            onMoveSelectionToList: { if !selection.ids.isEmpty { externalMoveUUIDs = Array(selection.ids) } },
            onRevealInList: { loc in revealInList(loc.id) },
            onRevealInGrid: { loc in revealInGrid(loc.id) },
            onToggleFlagLocation: { loc in toggleFlag([loc.id]) },
            onDeleteLocation: { loc in trashPins([loc.id]) },
            onOriginalFilePath: { loc in pin(byUUID: loc.id)?.originalFilePath },
            isSelectedPinned: allPins.contains(where: { $0.uuid == selectedLocation?.id }),
            boundaryPolygons: cachedBoundaryPolygons,
            boundaryOpacity: boundaryOpacity,
            showBoundaryNames: showBoundaryNames,
            boundaryNameLanguage: boundaryNameLanguage
        )
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                if let msg = backupStatusMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            if isBackupBusy { ProgressView().controlSize(.small) }
                            Text(msg)
                        }
                        if isBackupBusy, let frac = backupProgress {
                            ProgressView(value: frac)
                                .progressViewStyle(.linear)
                                .frame(width: 220)
                        }
                    }
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))
                    .transition(.opacity)
                }
                if let error = searchError {
                    Text(error)
                        .padding(8)
                        .background(.regularMaterial, in: .rect(cornerRadius: 8))
                }
            }
            // Drop below the top map toolbar so the progress capsule isn't covered by its
            // trailing icons (matches DebugPanelOverlay's .padding(.top, 58) clearance).
            .padding(.top, 58)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .animation(.easeInOut(duration: 0.2), value: backupStatusMessage != nil)
        }
        .overlay(alignment: .topLeading) {
            DebugPanelOverlay(onDeleteAllData: deleteAllData, onFindDuplicates: findDuplicates)
                .padding(.top, 58)
                .padding(.leading, 16)
        }
        .overlay(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 8) {
                layersButton
                photosButton
                boundaryButton
                lassoControls
                regionSearchOverlay
                pinSizeSlider
                if cyclingProvider == .cyclOSM {
                    cyclOSMLegend
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
                }
            }
            .padding(16)
            .animation(.easeInOut(duration: 0.2), value: cyclingProvider == .cyclOSM)
        }
    }

    var pinSizeSlider: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
            Slider(value: $pinSize, in: 0.4...2.5)
                .frame(width: 80)
                .controlSize(.mini)
            Image(systemName: "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
    }

    var regionSearchOverlay: some View {
        let hasActive = savedRegions.contains(where: \.isActive)
        return VStack(alignment: .leading, spacing: 6) {
            // Toggle chips for saved regions
            if !savedRegions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(savedRegions.indices, id: \.self) { i in
                        RegionChip(
                            name: savedRegions[i].name,
                            isActive: savedRegions[i].isActive,
                            onToggle: {
                                savedRegions[i].isActive.toggle()
                                applyActiveRegions()
                            },
                            onDelete: {
                                savedRegions.remove(at: i)
                                applyActiveRegions()
                            }
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            // Search field pill
            HStack(spacing: 4) {
                Image(systemName: "globe.europe.africa")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hasActive ? .blue : .primary)

                TextField("Country, state, city…", text: $regionQuery)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 140)
                    .onSubmit { Task { await runRegionSearch() } }

                if isRegionSearching {
                    ProgressView().controlSize(.mini)
                } else if !regionQuery.isEmpty {
                    Button {
                        regionQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { Task { await runRegionSearch() } } label: {
                        Image(systemName: "return")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(regionQuery.isEmpty)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(hasActive ? Color.blue.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
        }
        .animation(.easeInOut(duration: 0.2), value: savedRegions.count)
    }

    @MainActor
    func runRegionSearch() async {
        let q = regionQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isRegionSearching = true
        do {
            let result = try await NominatimService.shared.search(q)
            regionQuery = ""
            let newRegion = SavedRegion(name: result.name, polygon: result.polygon, isActive: true)
            // Deduplicate by name; if already saved just reactivate it
            if let existing = savedRegions.firstIndex(where: { $0.name == newRegion.name }) {
                savedRegions[existing].isActive = true
            } else {
                if savedRegions.count >= 3 { savedRegions.removeFirst() }
                savedRegions.append(newRegion)
            }
            applyActiveRegions()
            // Fit map to the new region's bounding box
            let b = result.bbox
            let center = CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2,
                                                longitude: (b.minLng + b.maxLng) / 2)
            let span = MKCoordinateSpan(latitudeDelta: (b.maxLat - b.minLat) * 1.15,
                                        longitudeDelta: (b.maxLng - b.minLng) * 1.15)
            mapController.setRegion(MKCoordinateRegion(center: center, span: span), animated: true)
        } catch {
            searchError = error.localizedDescription
        }
        isRegionSearching = false
    }

    // MARK: - Per-project saved-region persistence

    /// UserDefaults key for the currently open project's saved regions. Returns nil when no
    /// project is open (regions are project-scoped — different projects keep different filters).
    var savedRegionsKey: String? {
        openProjectUUID.isEmpty ? nil : "regions.\(openProjectUUID)"
    }

    /// Loads the open project's saved regions from UserDefaults and applies the active ones.
    func loadSavedRegions() {
        guard let key = savedRegionsKey,
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SavedRegion].self, from: data) else {
            savedRegions = []
            applyActiveRegions()
            return
        }
        savedRegions = decoded
        applyActiveRegions()
    }

    /// Persists the current saved regions under the open project's key.
    func persistSavedRegions() {
        guard let key = savedRegionsKey else { return }
        if savedRegions.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(savedRegions) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Syncs active saved regions → searchArea polygon + boundary polygon cache.
    func applyActiveRegions() {
        let active = savedRegions.filter(\.isActive)
        if active.isEmpty {
            searchArea.clear()
        } else {
            // Union all active region polygons into one combined point cloud for containment tests
            let combined = active.flatMap(\.polygon)
            searchArea.setPolygon(combined)
        }
        rebuildBoundaryPolygons()
    }

    var cyclOSMLegend: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CyclOSM Key")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 5)

            ForEach(Self.cyclOSMLegendItems, id: \.label) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.color)
                        .frame(width: 22, height: 9)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                }
                .padding(.bottom, 3)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    struct LegendItem {
        let color: Color
        let label: String
    }

    static let cyclOSMLegendItems: [LegendItem] = [
        LegendItem(color: Color(red: 0.38, green: 1.00, blue: 0.59), label: "Dedicated path"),
        LegendItem(color: Color(red: 0.73, green: 1.00, blue: 0.73), label: "Bike-friendly road"),
        LegendItem(color: Color(red: 0.69, green: 0.95, blue: 0.95), label: "Shared (foot + bike)"),
        LegendItem(color: Color(red: 0.00, green: 0.38, blue: 1.00), label: "Cycle street"),
        LegendItem(color: Color(red: 0.96, green: 0.77, blue: 0.77), label: "Road, bikes allowed"),
        LegendItem(color: Color(red: 0.83, green: 0.83, blue: 0.83), label: "No cycling"),
    ]

    func viewModeIcon(_ mode: ViewMode) -> String {
        switch mode { case .map: "map"; case .photos: "photo.stack"; case .script: "doc.text" }
    }
    func viewModeLabel(_ mode: ViewMode, photoCount: Int) -> String {
        switch mode {
        case .map: "Map"
        case .photos: photoCount > 0 ? "Photos (\(photoCount))" : "Photos"
        case .script: "Script"
        }
    }
    /// Scripts only appear in the toggle when the open project actually has one.
    var hasScripts: Bool {
        !(allProjects.first(where: { $0.uuid.uuidString == openProjectUUID })?.scripts.isEmpty ?? true)
    }

    var viewModeToggle: some View {
        let photoCount = locations.reduce(0) { $0 + $1.images.count }
        let modes: [ViewMode] = hasScripts ? [.map, .photos, .script] : [.map, .photos]
        return HStack(spacing: 2) {
            ForEach(modes, id: \.self) { mode in
                Button {
                    withAnimation(.spring(duration: 0.3)) { viewMode = mode }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: viewModeIcon(mode))
                            .font(.subheadline.weight(.medium))
                        Text(viewModeLabel(mode, photoCount: photoCount))
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(viewMode == mode ? .white : .white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(.white.opacity(viewMode == mode ? 0.18 : 0))
                    )
                    .animation(.spring(duration: 0.25), value: viewMode)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
        .padding(.top, 14)
    }

    var layersButton: some View {
        let active = mapStyle != .explore || cyclingProvider != nil
        return Button { showLayersPopover.toggle() } label: {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? .blue : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help("Map Layers")
        .popover(isPresented: $showLayersPopover, arrowEdge: .top) {
            LayersPopover(mapStyle: $mapStyle, cyclingProviderRaw: $cyclingProviderRaw, pinSize: $pinSize)
        }
    }

    var photosButton: some View {
        Button { showPhotoAnnotations.toggle() } label: {
            Image(systemName: showPhotoAnnotations ? "photo.fill" : "photo")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(showPhotoAnnotations ? .blue : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help(showPhotoAnnotations ? "Hide photos on pins" : "Show photos on pins")
    }

    var boundaryButton: some View {
        let active = showPrefectures || showMunicipalities
        return Button { showBoundaryPopover.toggle() } label: {
            Image(systemName: "map")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? .orange : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help("Japan Boundaries")
        .popover(isPresented: $showBoundaryPopover, arrowEdge: .top) {
            BoundarySettingsPopover(
                showPrefectures: $showPrefectures,
                showMunicipalities: $showMunicipalities,
                showNames: $showBoundaryNames,
                opacity: $boundaryOpacity,
                nameLanguage: $boundaryNameLanguage,
                isLoadingPrefectures: isLoadingPrefectures,
                isLoadingMunicipalities: isLoadingMunicipalities,
                prefectureCount: prefectureBoundaries.count,
                municipalityCount: municipalityBoundaries.count,
                error: boundaryError
            )
            .onChange(of: showPrefectures) { _, on in
                if on { Task { await loadPrefectures() } }
                else { rebuildBoundaryPolygons() }
            }
            .onChange(of: showMunicipalities) { _, on in
                if on { Task { await loadMunicipalities() } }
                else { rebuildBoundaryPolygons() }
            }
        }
    }

    // MARK: - Boundary helpers

    func rebuildBoundaryPolygons() {
        var result: [BoundaryPolygon] = []
        let japanActive: [JapanBoundaryService.BoundaryData] = (showPrefectures ? prefectureBoundaries : [])
            + (showMunicipalities ? municipalityBoundaries : [])
        for (idx, boundary) in japanActive.enumerated() {
            for ring in boundary.rings {
                guard ring.count >= 3 else { continue }
                var coords = ring
                let poly = BoundaryPolygon(coordinates: &coords, count: coords.count)
                poly.boundaryName = boundary.name
                poly.boundaryNameEn = boundary.nameEn
                poly.colorIndex = idx
                result.append(poly)
            }
        }
        // Active saved regions drawn as boundary overlays
        let activeRegions = savedRegions.filter(\.isActive)
        for (idx, region) in activeRegions.enumerated() {
            var coords = region.polygon
            guard coords.count >= 3 else { continue }
            let poly = BoundaryPolygon(coordinates: &coords, count: coords.count)
            poly.boundaryName = region.name
            poly.colorIndex = japanActive.count + idx
            result.append(poly)
        }
        cachedBoundaryPolygons = result
    }

    func loadPrefectures() async {
        guard prefectureBoundaries.isEmpty else { return }
        isLoadingPrefectures = true
        boundaryError = nil
        do {
            prefectureBoundaries = try await JapanBoundaryService.shared.fetchPrefectures()
            rebuildBoundaryPolygons()
        } catch {
            boundaryError = "Prefectures: \(error.localizedDescription)"
            showPrefectures = false
        }
        isLoadingPrefectures = false
    }

    func loadMunicipalities() async {
        isLoadingMunicipalities = true
        boundaryError = nil
        let region = mapController.mapView?.region
        let bbox = JapanBoundaryService.BoundingBox(
            south: (region?.center.latitude ?? 34) - (region?.span.latitudeDelta ?? 2) / 2,
            west:  (region?.center.longitude ?? 135) - (region?.span.longitudeDelta ?? 2) / 2,
            north: (region?.center.latitude ?? 34) + (region?.span.latitudeDelta ?? 2) / 2,
            east:  (region?.center.longitude ?? 135) + (region?.span.longitudeDelta ?? 2) / 2
        )
        do {
            municipalityBoundaries = try await JapanBoundaryService.shared.fetchMunicipalities(in: bbox)
            rebuildBoundaryPolygons()
        } catch {
            boundaryError = "Cities: \(error.localizedDescription)"
            showMunicipalities = false
        }
        isLoadingMunicipalities = false
    }

    var lassoControls: some View {
        Button {
            searchArea.isDrawing.toggle()
        } label: {
            Image(systemName: searchArea.isDrawing ? "xmark.circle.fill" : "lasso")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(searchArea.isDrawing ? .red : searchArea.isActive ? .blue : .primary)
                .mapControlChrome()
        }
        .buttonStyle(.plain)
        .help(searchArea.isDrawing ? "Cancel" : searchArea.isActive ? "Redraw search area" : "Draw search area")
        // Clear button floats above without changing the row height
        .overlay(alignment: .top) {
            if searchArea.isActive {
                Button(action: searchArea.clear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.multicolor)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Clear search area")
                .offset(y: -28)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.2), value: searchArea.isActive)
    }

    // MARK: - Search

    /// Current map/saved area, used to bias all searches toward what you're looking at.
    var searchRegion: GooglePlacesService.MapRegion? {
        searchArea.mapRegion ??
        (hasSavedRegion ? .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta) : nil)
    }

    /// Runs the active source's search. Google/Flickr/Wikimedia share the same
    /// wrapper (loading state, area filtering, map fit); only the service call differs.
    @MainActor
    func runSearch() async {
        guard rightPanelTab != .ai else { return }
        let requiresQuery: Bool = rightPanelTab == .google
        if requiresQuery && searchText.isEmpty { return }

        isSearching = true
        searchError = nil
        locations = []
        defer { isSearching = false }

        do {
            dlog("\(rightPanelTab.label) search: \"\(searchText)\"", level: .info, tag: "Search")
            var results: [ScoutLocation]
            switch rightPanelTab {
            case .google:
                results = try await GooglePlacesService.shared.search(query: searchText, region: searchRegion)
            case .foursquare:
                results = try await FoursquareService.shared.search(query: searchText.isEmpty ? nil : searchText, region: searchRegion, limit: Int(foursquareLimit))
            case .flickr:
                results = try await FlickrService.shared.search(query: searchText.isEmpty ? nil : searchText, region: searchRegion, limit: Int(flickrLimit))
            case .wikimedia:
                results = try await WikimediaService.shared.search(query: searchText, region: searchRegion, limit: Int(wikiLimit))
            case .ai:
                return
            }
            if searchArea.isActive { results = results.filter { searchArea.contains($0.coordinate) } }
            locations = results
            selectedLocation = nil
            dlog("\(rightPanelTab.label) returned \(results.count) results", level: .success, tag: "Search")
        } catch {
            searchError = error.localizedDescription
        }
        if !locations.isEmpty { fitMapToResults() }
    }

    @MainActor
    func runAISearch(query: String, model: ClaudeModel = .opus, extendedThinking: Bool = false) async {
        guard !query.isEmpty else { return }
        isAISearching = true
        searchError = nil
        locations = []
        chatMessages.append(.user(text: query))
        do {
            let aiRegion: GooglePlacesService.MapRegion?
            if searchArea.isActive {
                aiRegion = searchArea.mapRegion
            } else if aiConstrainToMap && hasSavedRegion {
                aiRegion = .init(centerLat: savedLat, centerLng: savedLng, latDelta: savedLatDelta, lngDelta: savedLngDelta)
            } else {
                aiRegion = nil
            }
            try await ClaudeService.shared.searchLocations(
                query: query,
                model: model.rawValue,
                extendedThinking: extendedThinking,
                mapRegion: aiRegion,
                onLocation: { location in
                    Task { @MainActor in
                        if self.searchArea.isActive && !self.searchArea.contains(location.coordinate) { return }
                        self.locations.append(location)
                    }
                },
                onStatus: { status in
                    Task { @MainActor in self.chatMessages.append(.status(text: status)) }
                }
            )
            chatMessages.append(.result(count: locations.count))
        } catch {
            chatMessages.append(.error(text: error.localizedDescription))
        }
        isAISearching = false
        if !locations.isEmpty { fitMapToResults() }
        // Refresh cost display now that we've consumed tokens
        let adminKey = APIKeyState.shared.anthropicAdminKey
        if !adminKey.isEmpty {
            await UsageCostService.shared.refresh(adminKey: adminKey)
        }
    }

    func fitMapToResults() {
        let coords = locations.map(\.coordinate)
        mapController.fit(coords, animated: true)
    }

    /// Frames every GPS pin in the open project (active-list pins, project photos, and
    /// unfiled pins — i.e. everything currently on the map for this project). Bound to "f".
    func frameAllProjectPins() {
        let coords = cachedProjectPins.map { $0.0.coordinate }
        guard !coords.isEmpty else { return }
        mapController.fit(coords, animated: true)
    }

    /// Clears the current search results everywhere they appear: the right-panel list,
    /// the map pins, and the "Search Results" section of the photo grid (all driven by
    /// the shared `locations` state).
    func clearSearchResults() {
        locations = []
        selectedLocation = nil
    }
}
