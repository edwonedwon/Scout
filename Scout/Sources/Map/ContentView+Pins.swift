import SwiftUI
import MapKit
import ScoutKit

// Pin caches, rotation, proximity ordering, select/zoom, save.
extension ContentView {
    /// Changes whenever any pin's list membership, sort order, or trashed state changes,
    /// even when total counts are unchanged — used to trigger a grid/map rebuild after a
    /// drag-reorder or a soft-delete (trashing a pin doesn't change any count). Also folds in
    /// each list's parent-folder so nesting/unnesting (which changes effective visibility)
    /// rebuilds too.
    var pinListAssignmentHash: Int {
        var h = allPins.reduce(0) { acc, pin in
            let listHash = pin.list?.id.hashValue ?? 0
            let trashed = pin.deletedAt == nil ? 0 : 1
            return acc ^ listHash ^ pin.sortOrder ^ pin.panelOrder ^ trashed
        }
        for list in allLists {
            h ^= (list.parentList?.id.hashValue ?? 0)
        }
        return h
    }

    /// Rotates the given pins 90° counter-clockwise (one quarter-turn) and refreshes caches.
    func rotatePins(_ uuids: [UUID]) {
        let pins = uuids.compactMap { id in pin(byUUID: id) }
        guard !pins.isEmpty else { return }
        for pin in pins {
            pin.rotationQuarterTurns = ((pin.rotationQuarterTurns - 1) % 4 + 4) % 4
        }
        rebuildPinCaches()
    }

    /// Rotates the pin whose photo file matches `url` (used by the carousel's R key).
    func rotatePin(forImageURL url: URL) {
        let path = url.path
        let pin = allPins.first { pin in
            if pin.originalFilePath == path { return true }
            if pin.photoFiles.contains(where: { PinPhotoStore.fileURL($0).path == path }) { return true }
            if pin.thumbnailFiles.contains(where: { PinPhotoStore.fileURL($0).path == path }) { return true }
            return false
        }
        guard let pin else { return }
        pin.rotationQuarterTurns = ((pin.rotationQuarterTurns - 1) % 4 + 4) % 4
        rebuildPinCaches()
    }

    /// A list is *effectively* visible only if its own eye is on AND every ancestor folder's
    /// eye is on. A folder thus acts as a master switch: turning it off hides everything
    /// inside it on the map/grid without changing the children's own eye states.
    func isEffectivelyActive(_ list: ListVM) -> Bool {
        var node: ListVM? = list
        while let n = node {
            // A trashed list (or any trashed ancestor) is never shown on the map/grid.
            if n.deletedAt != nil { return false }
            if !activeListIDs.contains(n.id) { return false }
            node = n.parentList
        }
        return true
    }

    func rebuildPinCaches() {
        let active = allLists.filter { isEffectivelyActive($0) }
        var mapPins: [(ScoutLocation, String)] = active.flatMap { list in
            list.pins.filter { $0.hasGPS && $0.deletedAt == nil && (!flaggedOnly || $0.isFlagged) }
                .map { (displayCache.location(for: $0), list.colorHex) }
        }
        for project in allProjects {
            // Skip uncategorized pins for projects whose "Uncategorized" eye is off.
            guard !hiddenUncategorizedProjectIDs.contains(project.id) else { continue }
            for pin in project.importedPhotos where pin.hasGPS && pin.deletedAt == nil && (!flaggedOnly || pin.isFlagged) {
                mapPins.append((displayCache.location(for: pin), Self.generalPinColor))
            }
        }
        // unfiledPins (list==nil, owningProject==nil) are orphaned data from old builds.
        // They have no sidebar entry and no visibility toggle, so exclude from map.
        cachedProjectPins = mapPins

        // Sectioned grid matching sidebar order: lists inside projects, then unfiled.
        var sections: [PhotoGridView.Section] = []
        for project in allProjects.sorted(by: { $0.createdAt < $1.createdAt }) {
            // Lists inside this project in exact sidebar order: top-level lists/folders by
            // panelOrder, and each folder immediately followed by its child lists (also by
            // panelOrder). Nested lists have a panelOrder relative to their folder, so a flat
            // sort would scramble them — we must walk the hierarchy. Only visible lists shown.
            let sortedLists = orderedListsForGrid(project)
                .filter { isEffectivelyActive($0) }
            for list in sortedLists {
                let ordered = displayCache.proximityOrdered(
                    list.id,
                    pins: list.pins.filter { $0.deletedAt == nil && (!flaggedOnly || $0.isFlagged) }.sorted { $0.sortOrder < $1.sortOrder }
                ) { proximityOrdered($0) }
                let locs = flaggedFirst(ordered
                    .map { displayCache.location(for: $0) }
                    .filter { !$0.images.isEmpty })
                if !locs.isEmpty {
                    sections.append(PhotoGridView.Section(
                        title: gridSectionTitle(for: list),
                        locations: locs,
                        color: Color(hexString: list.colorHex)
                    ))
                }
            }
            // Directly-imported photos (no list).
            // Skipped entirely when this project's "Uncategorized" eye is off.
            let importedPins = hiddenUncategorizedProjectIDs.contains(project.id)
                ? []
                : project.importedPhotos
                .filter { $0.deletedAt == nil && (!flaggedOnly || $0.isFlagged) }
                .sorted { $0.sortOrder < $1.sortOrder }
            let imported = flaggedFirst(displayCache.proximityOrdered(project.id, pins: importedPins) { proximityOrdered($0) }
                .map { displayCache.location(for: $0) }
                .filter { !$0.images.isEmpty })
            if !imported.isEmpty {
                sections.append(PhotoGridView.Section(title: "Uncategorized", locations: imported))
            }
        }
        // Active standalone lists not belonging to any project.
        for list in active.filter({ $0.project == nil }).sorted(by: { $0.createdAt < $1.createdAt }) {
            let ordered = displayCache.proximityOrdered(
                list.id,
                pins: list.pins.filter { $0.deletedAt == nil && (!flaggedOnly || $0.isFlagged) }.sorted { $0.sortOrder < $1.sortOrder }
            ) { proximityOrdered($0) }
            let locs = flaggedFirst(ordered
                .map { displayCache.location(for: $0) }
                .filter { !$0.images.isEmpty })
            if !locs.isEmpty {
                sections.append(PhotoGridView.Section(
                    title: list.name,
                    locations: locs,
                    color: Color(hexString: list.colorHex)
                ))
            }
        }
        // unfiledPins (list==nil, owningProject==nil) are orphaned data from old builds.
        // They have no sidebar entry and no visibility toggle, so exclude from the grid —
        // the grid must show nothing when no list/uncategorized is visible.
        cachedGridSections = sections
        // Tell the map the project-pin set changed so it re-diffs (only) now.
        pinCacheVersion &+= 1
    }

    /// Flattens a project's lists into sidebar display order: each top-level list/folder by
    /// panelOrder, with a folder immediately followed by its child lists (also by panelOrder).
    func orderedListsForGrid(_ project: ProjectVM) -> [ListVM] {
        var result: [ListVM] = []
        let topLevel = project.lists
            .filter { $0.parentList == nil }
            .sorted { $0.panelOrder < $1.panelOrder }
        for list in topLevel {
            result.append(list)
            if !list.childLists.isEmpty {
                result.append(contentsOf: list.childLists.sorted { $0.panelOrder < $1.panelOrder })
            }
        }
        return result
    }

    /// The grid location closest to the map's current center — used to scroll the grid to
    /// the photos in/nearest the zoomed-in map area. Skips photos with no real coordinate.
    func gridLocationNearestMapCenter() -> UUID? {
        guard let center = mapController.mapView?.region.center else { return nil }
        let locs = cachedGridSections.flatMap(\.locations)
            .filter { $0.coordinate.latitude != 0 || $0.coordinate.longitude != 0 }
        guard !locs.isEmpty else { return nil }
        let cosLat = cos(center.latitude * .pi / 180)
        func sqDist(_ c: CLLocationCoordinate2D) -> Double {
            let dLat = c.latitude - center.latitude
            let dLng = (c.longitude - center.longitude) * cosLat
            return dLat * dLat + dLng * dLng
        }
        return locs.min { sqDist($0.coordinate) < sqDist($1.coordinate) }?.id
    }

    /// Orders pins within a grid section so geographically close photos sit next to each
    /// other: a greedy nearest-neighbour walk starting from the north-west-most pin.
    /// GPS-less pins can't be placed spatially, so they keep their original order and go last.
    func proximityOrdered(_ pins: [PinVM]) -> [PinVM] {
        let gps = pins.filter { $0.hasGPS }
        let noGPS = pins.filter { !$0.hasGPS }
        guard gps.count > 2 else { return gps + noGPS }

        var remaining = gps
        // Start north-west (smallest longitude, then largest latitude) for a stable anchor.
        let startIdx = remaining.indices.min {
            (remaining[$0].longitude, -remaining[$0].latitude) <
            (remaining[$1].longitude, -remaining[$1].latitude)
        }!
        var ordered = [remaining.remove(at: startIdx)]
        while !remaining.isEmpty {
            let last = ordered[ordered.count - 1]
            // Longitude degrees shrink with latitude — scale so distances aren't skewed.
            let cosLat = cos(last.latitude * .pi / 180)
            func sqDist(_ p: PinVM) -> Double {
                let dLat = p.latitude - last.latitude
                let dLng = (p.longitude - last.longitude) * cosLat
                return dLat * dLat + dLng * dLng
            }
            let nextIdx = remaining.indices.min { sqDist(remaining[$0]) < sqDist(remaining[$1]) }!
            ordered.append(remaining.remove(at: nextIdx))
        }
        return ordered + noGPS
    }

    /// Tapping a saved pin in the sidebar selects it on the map and shows its popover —
    /// exactly as if it were clicked on the map. Activates its list first so it's visible
    /// (unfiled pins are always shown), then centers on it.
    func selectPin(_ pin: PinVM) {
        if viewMode == .photos {
            if photoViewer.isVisible { photoViewer.dismiss() }
            let id = pin.uuid
            highlightedPinID = (highlightedPinID == id) ? nil : id
            return
        }
        // Single-click in the sidebar list: just highlight the pin, no map pan.
        // Map panning only happens on double-click (zoomToPin) or clicking a map annotation.
        guard pin.hasGPS else { return }
        let location = pin.asScoutLocation()
        if selectedLocation?.id == location.id {
            selectedLocation = nil
            return
        }
        if let listID = pin.list?.id {
            activeListIDs.insert(listID)
        }
        selectedLocation = location
    }

    /// Double-clicking a sidebar pin: switch to the map if needed, then center AND zoom
    /// into the pin (unlike single-click selectPin, which preserves the current zoom).
    func zoomToPin(_ pin: PinVM) {
        guard pin.hasGPS else { return }
        let location = pin.asScoutLocation()
        let wasMap = (viewMode == .map)
        if !wasMap {
            withAnimation(.spring(duration: 0.3)) { viewMode = .map }
        }
        if let listID = pin.list?.id {
            activeListIDs.insert(listID)
        }
        selectedLocation = location
        // Delay the camera move when coming from photo view so the map is laid out first.
        let zoom = { mapController.center(on: location.coordinate, meters: 800, animated: true) }
        if wasMap { zoom() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { zoom() } }
    }

    /// Opens a pin in the carousel with all pinned locations as the navigation universe,
    /// in sidebar order (matching cachedGridSections). Used for double-clicking no-GPS pins.
    func openInCarousel(_ pin: PinVM) {
        let location = pin.asScoutLocation()
        // Build ordered universe from the grid sections (sidebar order).
        var seen = Set<UUID>()
        let allLocs = cachedGridSections.flatMap(\.locations).filter { seen.insert($0.id).inserted }
        let images = location.fullResImages.isEmpty ? location.images : location.fullResImages
        PhotoViewerState.shared.show(
            images: images,
            startingAt: 0,
            location: location,
            allLocations: allLocs
        )
    }

    /// Typed pin-by-uuid lookup — keeps big SwiftUI initializers from tripping the type-checker
    /// (inline `allPins.first(where:)` closures push inference over its time budget).
    func pin(byUUID id: UUID) -> PinVM? { allPins.first { $0.uuid == id } }

    /// Build + insert a store pin from a search/map ScoutLocation. Returns the new pin id.
    @discardableResult
    func insertStorePin(from loc: ScoutLocation, listId: String?, owningProjectId: String?, sortOrder: Int) -> String {
        let id = ScoutStore.newID()
        let rec = PinRecord(
            id: id, listId: listId, owningProjectId: owningProjectId,
            name: loc.name, notes: loc.description,
            latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude,
            hasGPS: true, gpsFromTimeline: false, isFlagged: loc.isFlagged,
            rotationQuarterTurns: 0, aspectRatio: 0, panelOrder: 0, sortOrder: sortOrder,
            statusRaw: loc.status.rawValue,
            imageSourceRaw: loc.images.first?.source.rawValue,
            imageURL: loc.images.first?.url?.absoluteString,
            googlePlaceId: loc.googlePlaceId,
            googleMapsURL: loc.googleMapsURL?.absoluteString,
            sourceURL: loc.sourceURL?.absoluteString,
            originalFilename: nil, photoFiles: [], thumbnailFiles: [],
            dateTaken: nil, createdAt: Date(), deletedAt: nil
        )
        Task { try? await ScoutStore.shared.insertPin(rec) }
        return id
    }

    func saveToList(_ location: ScoutLocation, _ list: ListVM) {
        // If this location is already a saved pin (id == pin.uuid), move it instead of copying.
        if let existing = allPins.first(where: { $0.uuid == location.id }) {
            movePin(existing, to: list)
            return
        }
        list.pins.forEach { $0.sortOrder += 1 }
        let id = insertStorePin(from: location, listId: list.id, owningProjectId: nil, sortOrder: 0)
        cachePhotos(pinId: id, from: location)
    }

    /// Save from the carousel: to a chosen list, or as a general unfiled pin (list == nil).
    func savePinned(_ location: ScoutLocation, to list: ListVM?) {
        // If this location is already a saved pin, move/reassign rather than duplicate.
        if let existing = allPins.first(where: { $0.uuid == location.id }) {
            if let list {
                movePin(existing, to: list)
            }
            // If list == nil the pin is already saved; nothing to do.
            return
        }
        if let list {
            list.pins.forEach { $0.sortOrder += 1 }
            let id = insertStorePin(from: location, listId: list.id, owningProjectId: nil, sortOrder: 0)
            cachePhotos(pinId: id, from: location)
        } else {
            let id = insertStorePin(from: location, listId: nil, owningProjectId: nil, sortOrder: 0)
            cachePhotos(pinId: id, from: location)
        }
    }

    /// Moves the pin backing the carousel's current location to the Trash, then refreshes
    /// caches. Soft-delete (not a hard SwiftData delete) keeps the photo recoverable and
    /// avoids the crash that hard-deleting a pin the grid/map still referenced could cause.
    /// The carousel has already dismissed itself by the time this runs.
    /// One-time data repair: reassign any DUPLICATE `uuid`s among lists/pins/projects.
    /// The whole app keys selection (and the map/grid) by `uuid` — `ScoutLocation.id` IS the
    /// pin uuid — so two rows sharing a uuid select together and can collide on the map. (Photo
    /// files are named by a separate id, so reassigning a pin's uuid never orphans its photos.)
    func repairDuplicateUUIDs() {
        // Store rows use unique UUID text primary keys, so duplicate-uuid repair is unnecessary
        // (offline inserts can't collide). We still purge any orphaned scene links (no list) that
        // could paint a "ghost" highlight in the script.
        for h in allScriptHighlights where h.list == nil {
            Task { try? await ScoutStore.shared.deleteHighlight(id: h.id) }
        }
    }

    /// Photo-grid section title for a list: the list name, prefixed by its folder ancestor
    /// chain ("Folder / List"), and never the project name — matching how it reads in the sidebar.
    func gridSectionTitle(for list: ListVM) -> String {
        var parts = [list.name]
        var node = list.parentList
        while let n = node { parts.insert(n.name, at: 0); node = n.parentList }
        return parts.joined(separator: " / ")
    }

    /// Stable partition: flagged locations first (keeping their order), then the rest.
    func flaggedFirst(_ locs: [ScoutLocation]) -> [ScoutLocation] {
        locs.filter(\.isFlagged) + locs.filter { !$0.isFlagged }
    }

    /// Toggle the "flagged" (favorite filming location) state of the given pins. If any are
    /// unflagged, flags them all; otherwise unflags them all. Used by the grid/map.
    func toggleFlag(_ uuids: [UUID]) {
        let pins = allPins.filter { uuids.contains($0.uuid) }
        guard !pins.isEmpty else { return }
        let shouldFlag = pins.contains { !$0.isFlagged }
        for pin in pins { pin.isFlagged = shouldFlag }
        rebuildPinCaches()   // isFlagged is in the cache signature → flagged-first re-sorts
    }
}
