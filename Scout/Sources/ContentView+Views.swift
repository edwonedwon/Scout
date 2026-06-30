import SwiftUI
import MapKit
import ScoutKit

// Right panel, center panel, empty state, map toolbar buttons.
extension ContentView {
    var scoutPanel: some View {
        VStack(spacing: 0) {
            // Tab bar: AI | Google | Flickr | Wiki
            Picker("Panel", selection: $rightPanelTab) {
                ForEach(RightPanelTab.allCases) { tab in
                    Label(tab.label, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 36)
            .padding(.bottom, 8)

            Divider()

            if rightPanelTab == .ai {
                AIChatView(
                    messages: $chatMessages,
                    isSearching: isAISearching,
                    onSend: { text, model, thinking in
                        Task { await runAISearch(query: text, model: model, extendedThinking: thinking) }
                    }
                )
            } else {
                searchContent
            }
        }
    }

    var searchContent: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
                TextField(rightPanelTab.placeholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let canBrowse = rightPanelTab == .wikimedia || rightPanelTab == .flickr || rightPanelTab == .foursquare
                        if canBrowse || !searchText.isEmpty { Task { await runSearch() } }
                    }
                Button { Task { await runSearch() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .disabled((searchText.isEmpty && rightPanelTab != .wikimedia && rightPanelTab != .flickr && rightPanelTab != .foursquare) || isSearching)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, (rightPanelTab == .wikimedia || rightPanelTab == .flickr || rightPanelTab == .foursquare) ? 4 : 8)

            if rightPanelTab == .wikimedia || rightPanelTab == .flickr || rightPanelTab == .foursquare {
                Button {
                    Task { await runSearch() }
                } label: {
                    Label("Browse in this area", systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSearching)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)

                HStack(spacing: 6) {
                    Text("Max results:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: rightPanelTab == .flickr ? $flickrLimit : rightPanelTab == .foursquare ? $foursquareLimit : $wikiLimit,
                        in: 10...(rightPanelTab == .foursquare ? 50 : 500), step: 10
                    )
                    Text("\(Int(rightPanelTab == .flickr ? flickrLimit : rightPanelTab == .foursquare ? foursquareLimit : wikiLimit))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

            Divider()

            if !locations.isEmpty {
                HStack {
                    Text("\(locations.count) results")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        clearSearchResults()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }

            List(locations, selection: $selectedLocation) { location in
                LocationRow(location: location)
                    .draggable(location)
                    .tag(location)
                    .contextMenu {
                        let projectLists = openProjectLists
                        if !projectLists.isEmpty {
                            Menu {
                                ForEach(projectLists) { list in
                                    Button { saveToList(location, list) } label: {
                                        Label(list.name, systemImage: "mappin.circle")
                                    }
                                }
                            } label: {
                                Label("Save to List", systemImage: "folder.badge.plus")
                            }
                        }
                    }
            }
            .overlay {
                if locations.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: rightPanelTab.emptyIcon,
                        description: Text(rightPanelTab.emptyHint)
                    )
                }
            }
        }
    }

    // MARK: - Center panel (map or photo grid)

    var centerPanel: some View {
        // Both views stay in the hierarchy at all times:
        // - Map: never torn down so MapKit/CVDisplayLink stay alive
        // - PhotoGrid: never torn down so scroll position survives "Show on Map" round-trips
        ZStack {
            scoutMap
                .zIndex(0)
            PhotoGridView(
                selection: selection,
                locations: locations,
                pinnedSections: cachedGridSections,
                dataVersion: pinCacheVersion,
                highlightedLocationID: highlightedPinID,
                scrollTargetID: gridScrollTargetID,
                onClearSearchResults: clearSearchResults,
                onSelectLocation: { id in highlightedPinID = id },
                onDoubleSelectLocation: { id in
                    if let pin = pin(byUUID: id) {
                        openInCarousel(pin)
                    }
                },
                onMoveToList: { uuids in externalMoveUUIDs = uuids },
                onToggleFlag: { uuids in toggleFlag(uuids) },
                onRevealInList: { id in revealInList(id) },
                onRevealOnMap: { id in revealOnMap(id) },
                onDelete: { uuids in trashPins(uuids) },
                onRotate: { uuids in rotatePins(uuids) },
                originalFilePath: { id in pin(byUUID: id)?.originalFilePath }
            )
                .ignoresSafeArea()
                .opacity(viewMode == .photos ? 1 : 0)
                .allowsHitTesting(viewMode == .photos)
                .zIndex(10)
            ScriptView(script: activeScript,
                       highlights: activeScriptHighlights,
                       onAssign: { range in beginScriptAssign(range) },
                       onAssignNewList: { range in beginScriptAssignNewList(range) },
                       onRemoveHighlight: { range in removeScriptHighlight(overlapping: range) },
                       onHighlightClick: { offset in selectListForScriptOffset(offset) },
                       zoom: CGFloat(scriptZoom),
                       scrollTarget: scriptScrollTarget)
                .opacity(viewMode == .script ? 1 : 0)
                .allowsHitTesting(viewMode == .script)
                .zIndex(15)
            if photoViewer.isVisible {
                PhotoViewerOverlay(availableLists: openProjectLists, onSave: savePinned,
                                   onRotate: { url in rotatePin(forImageURL: url) },
                                   onDelete: { loc in deletePinFromCarousel(loc) })
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: photoViewer.isVisible)
                    .zIndex(20)
            }
            // No project open → hide the (still-alive) map/grid behind an app splash.
            if openProject == nil {
                projectEmptyState
                    .zIndex(30)
            }
        }
        // M key: open move sheet from photo grid or map selection (sidebar handles its own M).
        .background {
            Button("") {
                let uuids: [UUID] = {
                    // The shared selection (sidebar/grid/map all write it) wins, then the
                    // highlighted grid pin, then the map popover's pin.
                    if !selection.ids.isEmpty { return Array(selection.ids) }
                    if let id = highlightedPinID { return [id] }
                    if let id = selectedLocation?.id { return [id] }
                    return []
                }()
                if !uuids.isEmpty { externalMoveUUIDs = uuids }
            }
            .keyboardShortcut("m", modifiers: [])
            // Disable while the move sheet is open (so "m" typed into its search field can't
            // re-fire this), and in Script mode (where "m" assigns the selected script range to
            // a list via the Script view's own key handler).
            .disabled(showExternalMoveSheet || viewMode == .script)
            .opacity(0)
            .allowsHitTesting(false)
        }
        // U key: reset/toggle user-location follow — same as the location button on the map.
        .background {
            Button("") { mapController.toggleTracking() }
                .keyboardShortcut("u", modifiers: [])
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Delete key in grid/map mode: trash every selected photo. The sidebar has its own
        // delete handler for when it's focused; this covers the center panel.
        .background {
            Button("", action: deleteSelectedPhotos)
                .keyboardShortcut(.delete, modifiers: [])
                // Not while reading a script — Delete there must not trash selected photos.
                .disabled(viewMode == .script)
                .opacity(0)
                .allowsHitTesting(false)
        }
        // Cmd +/- (and Cmd 0 to reset): zoom the Script page in/out. Only in Script mode.
        .background {
            Group {
                Button("") { scriptZoom = min(scriptZoom + 0.1, 3.0) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("") { scriptZoom = min(scriptZoom + 0.1, 3.0) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { scriptZoom = max(scriptZoom - 0.1, 0.5) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("") { scriptZoom = 1.3 }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .disabled(viewMode != .script)
            .opacity(0)
            .allowsHitTesting(false)
        }
        // Clear the shared selection once the move sheet has closed.
        // Also open the sheet here when the sidebar is hidden (ProjectsPanel is not in hierarchy).
        .onChange(of: externalMoveUUIDs) { _, ids in
            if ids.isEmpty {
                selection.ids = []
                showExternalMoveSheet = false
            } else if !showProjectsPanel {
                showExternalMoveSheet = true
            }
        }
        .sheet(isPresented: $showExternalMoveSheet, onDismiss: { externalMoveUUIDs = [] }) {
            if let project = allProjects.first(where: { $0.uuid.uuidString == openProjectUUID }) {
                MoveToListSheet(
                    project: project,
                    onMove: { list in
                        let pins = externalMoveUUIDs.compactMap { pin(byUUID: $0) }
                        for p in pins { movePin(p, to: list) }
                        externalMoveUUIDs = []
                        selection.ids = []
                        showExternalMoveSheet = false
                    },
                    onDismiss: { externalMoveUUIDs = []; showExternalMoveSheet = false }
                )
            }
        }
        // Script mode: pick which list a highlighted script section belongs to.
        .sheet(isPresented: $showScriptListPicker, onDismiss: { pendingScriptRange = nil }) {
            if let project = openProject {
                MoveToListSheet(
                    project: project,
                    onMove: { list in assignScriptSelection(to: list) },
                    onDismiss: { showScriptListPicker = false; pendingScriptRange = nil }
                )
            }
        }
        // Script mode: create a new list (optionally nested in a folder) and assign the scene to it.
        .sheet(isPresented: $showScriptNewListSheet, onDismiss: { pendingScriptRange = nil }) {
            if let project = openProject {
                NewListForSceneSheet(
                    project: project,
                    name: $scriptNewListName,
                    onDismiss: { showScriptNewListSheet = false; pendingScriptRange = nil },
                    onConfirm: { name, parent in createListAndAssignScene(named: name, parent: parent) }
                )
            }
        }
        .overlay(alignment: .top) {
            // Hidden on the empty-state splash (no project open) so only the icon + name show.
            if openProject != nil {
                HStack {
                    panelToggleButton(
                        icon: showProjectsPanel ? "folder.fill" : "folder",
                        action: { showProjectsPanel.toggle() }
                    )
                    Spacer()
                    viewModeToggle
                    Spacer()
                    HStack(spacing: 4) {
                        collaborationButton
                        // Focus + user-location are map-only; hide them in the photo grid.
                        if viewMode != .photos {
                            fitAllPinsButton
                            locationTrackingButton
                        }
                        panelToggleButton(
                            icon: "magnifyingglass",
                            circle: true,
                            action: { showRightPanel.toggle() }
                        )
                    }
                }
                .padding(.top, 14)
                .padding(.horizontal, 8)
            }
        }
    }

    /// Shown over the center panel when no project is open: just the app icon and name.
    var projectEmptyState: some View {
        ZStack {
            // Plain system background — adapts to light/dark (was a hardcoded dark that looked
            // wrong in Light mode). The map/photos/script all sit behind this when no project is open.
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            #else
            Color(.systemBackground).ignoresSafeArea()
            #endif
            VStack(spacing: 16) {
                #if os(macOS)
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 128, height: 128)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                #else
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 96))
                    .foregroundStyle(.secondary)
                #endif
                Text("Script Scout")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var fitAllPinsButton: some View {
        Button { frameAllProjectPins() } label: {
            Image(systemName: "viewfinder")
                .font(.subheadline.weight(.medium))
                .mapControlChrome(diameter: 32, circle: false)
        }
        .buttonStyle(.plain)
        .disabled(cachedProjectPins.isEmpty)
    }

    /// Collaboration button (Apple Notes-style). Opens a popover to see/add people on this
    /// project. UI shell only for now — wired to iCloud sharing per docs/collaboration-plan.md.
    var collaborationButton: some View {
        Button { showCollaborationPopover.toggle() } label: {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.subheadline.weight(.medium))
                .mapControlChrome(diameter: 32, circle: false)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showCollaborationPopover, arrowEdge: .bottom) {
            collaborationPopover
        }
    }

    var collaborationPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Collaboration").font(.headline)
                    Text(openProject?.name ?? "Project").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()
            // Current participants (just the owner until sharing is live).
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("You").font(.subheadline.weight(.medium))
                    Text("Owner").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            // Share via the system CloudKit sharing UI (add people by Apple ID, set
            // editor/viewer, copy invite link). Lists, pins, notes, scripts + photos travel.
            VStack(alignment: .leading, spacing: 8) {
                Button { shareProject() } label: {
                    Label("Share Project…", systemImage: "person.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(openProject == nil)
                Text("Opens the iCloud sharing panel. Invitees need the app and must accept the invite; they can view or edit per the permission you choose.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    func shareProject() {
        guard let project = openProject else { return }
        showCollaborationPopover = false
        sharingProject = project
    }

    var locationTrackingButton: some View {
        #if os(macOS)
        // macOS MapKit has no MKUserTrackingButton, so drive the map directly.
        let tracking = mapController.userTrackingMode == .follow
        return Button { mapController.toggleTracking() } label: {
            Image(systemName: tracking ? "location.fill" : "location")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tracking ? .blue : .primary)
                .mapControlChrome(diameter: 32, circle: false)
        }
        .buttonStyle(.plain)
        #else
        return UserTrackingButtonView(controller: mapController)
            .mapControlChrome(diameter: 32, circle: false)
        #endif
    }

    func panelToggleButton(icon: String, circle: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .mapControlChrome(diameter: 32, circle: circle)
        }
        .buttonStyle(.plain)
    }
}
