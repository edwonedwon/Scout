// StoreVMs.swift — store-backed view-model adapter for the Mac UI (migration plan P2, stage 2).
//
// The Mac UI (ContentView/ProjectsPanel + subviews) was built on Core Data NSManagedObjects, passed
// throughout the view tree, two-way-bound, and keyed in selection sets. To move it onto ScoutStore
// (PowerSync SQLite) with the least structural churn, these reference-type view-models MIRROR the
// NSManagedObject API surface (same property names, `@Published` for two-way bindings, relationship
// accessors that walk the in-memory graph). A single `MacStore` watches the whole DB and keeps a
// stable VM per row id, so SwiftUI identity holds across sync updates and @ObservedObject works.
//
// Mutations write through to ScoutStore; the resulting watch update reconciles the VM graph.

import Foundation
import Combine
import CoreLocation
import SwiftUI
import ScoutKit

// MARK: - MacStore: the live VM graph over ScoutStore

@MainActor
final class MacStore: ObservableObject {
    static let shared = MacStore()

    // Stable VM per id (reused across updates so SwiftUI identity + @ObservedObject hold).
    private var projectVMs: [String: ProjectVM] = [:]
    private var listVMs: [String: ListVM] = [:]
    private var pinVMs: [String: PinVM] = [:]
    private var scriptVMs: [String: ScriptVM] = [:]
    private var highlightVMs: [String: HighlightVM] = [:]

    // Grouping indexes, rebuilt once per reconcile (O(n)) so relationship accessors are O(1)/O(k)
    // dictionary lookups instead of O(n) filters over the whole table on EVERY SwiftUI render.
    // Without these, e.g. a project's pinCount is O(lists × pins) and pegs the main thread on large
    // libraries during the initial sync's rapid watch emissions.
    private var pinsByList: [String: [PinVM]] = [:]
    private var loosePinsByProject: [String: [PinVM]] = [:]
    private var listsByProject: [String: [ListVM]] = [:]
    private var childListsByParent: [String: [ListVM]] = [:]
    private var scriptsByProject: [String: [ScriptVM]] = [:]
    private var highlightsByScript: [String: [HighlightVM]] = [:]
    private var highlightsByList: [String: [HighlightVM]] = [:]

    // Published snapshots (all rows incl. trashed; views filter via `deletedAt`).
    @Published private(set) var projects: [ProjectVM] = []
    @Published private(set) var lists: [ListVM] = []
    @Published private(set) var pins: [PinVM] = []
    @Published private(set) var scripts: [ScriptVM] = []
    @Published private(set) var highlights: [HighlightVM] = []

    private var tasks: [Task<Void, Never>] = []
    let store = ScoutStore.shared

    private init() {
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllProjectsRaw() { self?.applyProjects(rows) } } catch {}
        })
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllListsRaw() { self?.applyLists(rows) } } catch {}
        })
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllPinsRaw() { self?.applyPins(rows) } } catch {}
        })
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllScriptsRaw() { self?.applyScripts(rows) } } catch {}
        })
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllHighlightsRaw() { self?.applyHighlights(rows) } } catch {}
        })
    }
    deinit { tasks.forEach { $0.cancel() } }

    // MARK: Lookups (used by relationship accessors)

    func project(_ id: String?) -> ProjectVM? { id.flatMap { projectVMs[$0] } }
    func list(_ id: String?) -> ListVM? { id.flatMap { listVMs[$0] } }
    func pin(_ id: String?) -> PinVM? { id.flatMap { pinVMs[$0] } }
    func script(_ id: String?) -> ScriptVM? { id.flatMap { scriptVMs[$0] } }

    func listsIn(projectId: String) -> [ListVM] { listsByProject[projectId] ?? [] }
    func childLists(of listId: String) -> [ListVM] { childListsByParent[listId] ?? [] }
    func pinsIn(listId: String) -> [PinVM] { pinsByList[listId] ?? [] }
    func loosePins(projectId: String) -> [PinVM] { loosePinsByProject[projectId] ?? [] }
    func scriptsIn(projectId: String) -> [ScriptVM] { scriptsByProject[projectId] ?? [] }
    func highlightsIn(scriptId: String) -> [HighlightVM] { highlightsByScript[scriptId] ?? [] }
    func sceneLinks(listId: String) -> [HighlightVM] { highlightsByList[listId] ?? [] }

    // MARK: Index rebuilds (run once at the end of each reconcile)

    private func reindexPins() {
        var byList: [String: [PinVM]] = [:]
        var loose: [String: [PinVM]] = [:]
        for vm in pins {
            if let lid = vm.listId { byList[lid, default: []].append(vm) }
            else if let pid = vm.owningProjectId { loose[pid, default: []].append(vm) }
        }
        pinsByList = byList; loosePinsByProject = loose
    }
    private func reindexLists() {
        var byProject: [String: [ListVM]] = [:]
        var byParent: [String: [ListVM]] = [:]
        for vm in lists {
            if let pid = vm.projectId { byProject[pid, default: []].append(vm) }
            if let par = vm.parentListId { byParent[par, default: []].append(vm) }
        }
        listsByProject = byProject; childListsByParent = byParent
    }
    private func reindexScripts() {
        var byProject: [String: [ScriptVM]] = [:]
        for vm in scripts { if let pid = vm.projectId { byProject[pid, default: []].append(vm) } }
        scriptsByProject = byProject
    }
    private func reindexHighlights() {
        var byScript: [String: [HighlightVM]] = [:]
        var byList: [String: [HighlightVM]] = [:]
        for vm in highlights {
            if let sid = vm.scriptId { byScript[sid, default: []].append(vm) }
            if let lid = vm.listId { byList[lid, default: []].append(vm) }
        }
        highlightsByScript = byScript; highlightsByList = byList
    }

    // MARK: Reconciliation (upsert stable VMs, drop removed)

    private func applyProjects(_ rows: [ProjectRecord]) {
        var seen = Set<String>()
        for r in rows { seen.insert(r.id); (projectVMs[r.id] ?? { let vm = ProjectVM(r, self); projectVMs[r.id] = vm; return vm }()).apply(r) }
        projectVMs = projectVMs.filter { seen.contains($0.key) }
        projects = rows.compactMap { projectVMs[$0.id] }
    }
    private func applyLists(_ rows: [ListRecord]) {
        var seen = Set<String>()
        for r in rows { seen.insert(r.id); (listVMs[r.id] ?? { let vm = ListVM(r, self); listVMs[r.id] = vm; return vm }()).apply(r) }
        listVMs = listVMs.filter { seen.contains($0.key) }
        lists = rows.compactMap { listVMs[$0.id] }
        reindexLists()
    }
    private func applyPins(_ rows: [PinRecord]) {
        var seen = Set<String>()
        for r in rows { seen.insert(r.id); (pinVMs[r.id] ?? { let vm = PinVM(r, self); pinVMs[r.id] = vm; return vm }()).apply(r) }
        pinVMs = pinVMs.filter { seen.contains($0.key) }
        pins = rows.compactMap { pinVMs[$0.id] }
        reindexPins()
    }
    private func applyScripts(_ rows: [ScriptRecord]) {
        var seen = Set<String>()
        for r in rows { seen.insert(r.id); (scriptVMs[r.id] ?? { let vm = ScriptVM(r, self); scriptVMs[r.id] = vm; return vm }()).apply(r) }
        scriptVMs = scriptVMs.filter { seen.contains($0.key) }
        scripts = rows.compactMap { scriptVMs[$0.id] }
        reindexScripts()
    }
    private func applyHighlights(_ rows: [HighlightRecord]) {
        var seen = Set<String>()
        for r in rows { seen.insert(r.id); (highlightVMs[r.id] ?? { let vm = HighlightVM(r, self); highlightVMs[r.id] = vm; return vm }()).apply(r) }
        highlightVMs = highlightVMs.filter { seen.contains($0.key) }
        highlights = rows.compactMap { highlightVMs[$0.id] }
        reindexHighlights()
    }
}

// Identity-based Hashable/Equatable (by row id) so VMs work in navigationDestination, onChange,
// Set, and ForEach selection just like the Core Data objects did.
extension ProjectVM: Hashable { nonisolated static func == (l: ProjectVM, r: ProjectVM) -> Bool { l.id == r.id }; nonisolated func hash(into h: inout Hasher) { h.combine(id) } }
extension ListVM: Hashable { nonisolated static func == (l: ListVM, r: ListVM) -> Bool { l.id == r.id }; nonisolated func hash(into h: inout Hasher) { h.combine(id) } }
extension PinVM: Hashable { nonisolated static func == (l: PinVM, r: PinVM) -> Bool { l.id == r.id }; nonisolated func hash(into h: inout Hasher) { h.combine(id) } }
extension ScriptVM: Hashable { nonisolated static func == (l: ScriptVM, r: ScriptVM) -> Bool { l.id == r.id }; nonisolated func hash(into h: inout Hasher) { h.combine(id) } }
extension HighlightVM: Hashable { nonisolated static func == (l: HighlightVM, r: HighlightVM) -> Bool { l.id == r.id }; nonisolated func hash(into h: inout Hasher) { h.combine(id) } }

// MARK: - Write-through helpers
//
// VM property setters persist to ScoutStore so existing `vm.prop = x` mutations in the views Just
// Work. `applying` suppresses the write-through while reconciling from a watch update (otherwise
// every incoming sync would echo back as a write).

@MainActor
private func persistChange(_ applying: Bool, _ op: @escaping () async throws -> Void) {
    guard !applying else { return }
    Task { try? await op() }
}

// MARK: - Project

@MainActor
final class ProjectVM: ObservableObject, Identifiable {
    let id: String
    unowned let s: MacStore
    private var applying = false
    @Published var name: String = "" { didSet { persistChange(applying) { [id, name] in try await ScoutStore.shared.renameProject(id: id, name: name) } } }
    @Published var notes: String = "" { didSet { persistChange(applying) { [id, notes] in try await ScoutStore.shared.setProjectNotes(id: id, notes: notes) } } }
    @Published var uncategorizedPanelOrder: Int = 0 { didSet { persistChange(applying) { [id, uncategorizedPanelOrder] in try await ScoutStore.shared.setUncategorizedPanelOrder(projectId: id, order: uncategorizedPanelOrder) } } }
    var createdAt: Date = Date()
    @Published var deletedAt: Date? { didSet { persistChange(applying) { [id, deletedAt] in
        if deletedAt == nil { try await ScoutStore.shared.restoreProject(id: id) } else { try await ScoutStore.shared.softDeleteProject(id: id) } } } }

    init(_ r: ProjectRecord, _ s: MacStore) { self.id = r.id; self.s = s; apply(r) }
    func apply(_ r: ProjectRecord) {
        applying = true; defer { applying = false }
        name = r.name; notes = r.notes; uncategorizedPanelOrder = r.uncategorizedPanelOrder
        createdAt = r.createdAt; deletedAt = r.deletedAt
    }

    var uuid: UUID { UUID(uuidString: id) ?? UUID() }
    var lists: [ListVM] { s.listsIn(projectId: id) }
    var liveLists: [ListVM] { lists.filter { $0.deletedAt == nil } }
    var importedPhotos: [PinVM] { s.loosePins(projectId: id) }
    var livePhotos: [PinVM] { importedPhotos.filter { $0.deletedAt == nil } }
    var scripts: [ScriptVM] { s.scriptsIn(projectId: id) }
}

// MARK: - Location list

@MainActor
final class ListVM: ObservableObject, Identifiable {
    let id: String
    unowned let s: MacStore
    private var applying = false
    @Published var name: String = "" { didSet { persistChange(applying) { [id, name] in try await ScoutStore.shared.renameList(id: id, name: name) } } }
    @Published var colorHex: String = "#FF6B35" { didSet { persistChange(applying) { [id, colorHex] in try await ScoutStore.shared.setListColor(id: id, colorHex: colorHex) } } }
    @Published var sortOrder: Int = 0 { didSet { persistChange(applying) { [id, sortOrder] in try await ScoutStore.shared.setListSortOrder(id: id, order: sortOrder) } } }
    @Published var panelOrder: Int = 0 { didSet { persistChange(applying) { [id, panelOrder] in try await ScoutStore.shared.setListPanelOrder(id: id, order: panelOrder) } } }
    @Published var sceneType: String? { didSet { persistChange(applying) { [id, sceneType] in try await ScoutStore.shared.setListSceneType(id: id, sceneType: sceneType) } } }
    @Published var deletedAt: Date? { didSet { persistChange(applying) { [id, deletedAt] in
        if deletedAt == nil { try await ScoutStore.shared.restoreList(id: id) } else { try await ScoutStore.shared.softDeleteList(id: id) } } } }
    var createdAt: Date = Date()
    private(set) var projectId: String?
    private(set) var parentListId: String?

    init(_ r: ListRecord, _ s: MacStore) { self.id = r.id; self.s = s; apply(r) }
    func apply(_ r: ListRecord) {
        applying = true; defer { applying = false }
        name = r.name; colorHex = r.colorHex; sortOrder = r.sortOrder; panelOrder = r.panelOrder
        sceneType = r.sceneType; deletedAt = r.deletedAt; createdAt = r.createdAt
        projectId = r.projectId; parentListId = r.parentListId
    }

    var uuid: UUID { UUID(uuidString: id) ?? UUID() }
    var project: ProjectVM? { s.project(projectId) }
    var parentList: ListVM? { s.list(parentListId) }
    var pins: [PinVM] { s.pinsIn(listId: id) }
    var livePins: [PinVM] { pins.filter { $0.deletedAt == nil } }
    var childLists: [ListVM] { s.childLists(of: id) }
    var liveChildLists: [ListVM] { childLists.filter { $0.deletedAt == nil } }
    var sceneLinks: [HighlightVM] { s.sceneLinks(listId: id) }

    var displayColor: Color { Color(hexString: colorHex) }

    /// Canonical list-color palette (was LocationListData.palette before the Core Data removal).
    static let palette = [
        "#FF6B35", // orange
        "#2196F3", // blue
        "#4CAF50", // green
        "#9C27B0", // purple
        "#E91E63", // pink
        "#00BCD4", // cyan
        "#FF5722", // deep orange
        "#FFEB3B", // yellow
    ]
}

// MARK: - Pinned location

@MainActor
final class PinVM: ObservableObject, Identifiable {
    let id: String
    unowned let s: MacStore
    private var applying = false
    @Published var name: String = "" { didSet { persistChange(applying) { [id, name] in try await ScoutStore.shared.renamePin(id: id, name: name) } } }
    @Published var notes: String = "" { didSet { persistChange(applying) { [id, notes] in try await ScoutStore.shared.setPinNotes(id: id, notes: notes) } } }
    @Published var latitude: Double = 0 { didSet { persistChange(applying) { [id, latitude, longitude, hasGPS] in try await ScoutStore.shared.setPinCoordinate(id: id, latitude: latitude, longitude: longitude, hasGPS: hasGPS) } } }
    @Published var longitude: Double = 0 { didSet { persistChange(applying) { [id, latitude, longitude, hasGPS] in try await ScoutStore.shared.setPinCoordinate(id: id, latitude: latitude, longitude: longitude, hasGPS: hasGPS) } } }
    @Published var statusRaw: String = "" { didSet { persistChange(applying) { [id, statusRaw] in try await ScoutStore.shared.setPinStatus(id: id, statusRaw: statusRaw) } } }
    @Published var sortOrder: Int = 0 { didSet { persistChange(applying) { [id, sortOrder] in try await ScoutStore.shared.setPinSortOrder(id: id, order: sortOrder) } } }
    @Published var panelOrder: Int = 0 { didSet { persistChange(applying) { [id, panelOrder] in try await ScoutStore.shared.setPinPanelOrder(id: id, order: panelOrder) } } }
    @Published var isFlagged: Bool = false { didSet { persistChange(applying) { [id, isFlagged] in try await ScoutStore.shared.setPinFlagged(id: id, flagged: isFlagged) } } }
    @Published var rotationQuarterTurns: Int = 0 { didSet { persistChange(applying) { [id, rotationQuarterTurns] in try await ScoutStore.shared.setPinRotation(id: id, quarterTurns: rotationQuarterTurns) } } }
    @Published var aspectRatio: Double = 0 { didSet { persistChange(applying) { [id, aspectRatio] in try await ScoutStore.shared.setPinAspectRatio(id: id, ratio: aspectRatio) } } }
    @Published var deletedAt: Date? { didSet { persistChange(applying) { [id, deletedAt] in
        if deletedAt == nil { try await ScoutStore.shared.restorePin(id: id) } else { try await ScoutStore.shared.softDeletePin(id: id) } } } }
    var imageURL: String?
    var googlePlaceId: String?
    var sourceURLString: String?
    var googleMapsURLString: String?
    var imageSourceRaw: String?
    var originalFilename: String?
    /// Local absolute path to the original file, if downloaded on this device. Not in the synced
    /// schema (originals are opt-in via Supabase Storage); nil unless a local original is present.
    var originalFilePath: String?
    var hasGPS: Bool = true
    var gpsFromTimeline: Bool = false
    var dateTaken: Date?
    var createdAt: Date = Date()
    var photoFiles: [String] = []
    var thumbnailFiles: [String] = []
    private(set) var listId: String?
    private(set) var owningProjectId: String?

    init(_ r: PinRecord, _ s: MacStore) { self.id = r.id; self.s = s; apply(r) }
    func apply(_ r: PinRecord) {
        applying = true; defer { applying = false }
        name = r.name; notes = r.notes; latitude = r.latitude; longitude = r.longitude
        statusRaw = r.statusRaw; sortOrder = r.sortOrder; panelOrder = r.panelOrder
        isFlagged = r.isFlagged; rotationQuarterTurns = r.rotationQuarterTurns; aspectRatio = r.aspectRatio
        deletedAt = r.deletedAt; imageURL = r.imageURL; googlePlaceId = r.googlePlaceId
        sourceURLString = r.sourceURL; googleMapsURLString = r.googleMapsURL; imageSourceRaw = r.imageSourceRaw
        originalFilename = r.originalFilename; hasGPS = r.hasGPS; gpsFromTimeline = r.gpsFromTimeline
        dateTaken = r.dateTaken; createdAt = r.createdAt; photoFiles = r.photoFiles
        thumbnailFiles = r.thumbnailFiles; listId = r.listId; owningProjectId = r.owningProjectId
        // Local-only: the absolute path to this device's original file, if a relink found one.
        originalFilePath = OriginalPathStore.shared.path(for: id)
    }

    var uuid: UUID { UUID(uuidString: id) ?? UUID() }
    var list: ListVM? { s.list(listId) }
    var owningProject: ProjectVM? { s.project(owningProjectId) }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    var thumbnailImages: [ScoutImage] {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .imported
        let files = thumbnailFiles.isEmpty ? photoFiles : thumbnailFiles
        return files.map { ScoutImage(url: PinPhotoStore.fileURL($0), source: source, dateTaken: dateTaken, rotationQuarterTurns: rotationQuarterTurns, aspectRatio: aspectRatio) }
    }
    var fullResImages: [ScoutImage] {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .imported
        if !photoFiles.isEmpty {
            return photoFiles.map { ScoutImage(url: PinPhotoStore.fileURL($0), source: source, dateTaken: dateTaken, rotationQuarterTurns: rotationQuarterTurns) }
        }
        return []
    }

    func asScoutLocation() -> ScoutLocation {
        let source = imageSourceRaw.flatMap(ScoutImage.ImageSource.init(rawValue:)) ?? .googleMaps
        let images: [ScoutImage]
        if !photoFiles.isEmpty || !thumbnailFiles.isEmpty {
            images = thumbnailImages
        } else if let imageURL, let url = URL(string: imageURL) {
            images = [ScoutImage(url: url, source: source)]
        } else {
            images = []
        }
        return ScoutLocation(
            id: uuid, name: name, description: notes,
            coordinate: coordinate,
            sourceURL: sourceURLString.flatMap { URL(string: $0) },
            images: images, fullResImages: fullResImages,
            googleMapsURL: googleMapsURLString.flatMap { URL(string: $0) },
            googlePlaceId: googlePlaceId,
            status: LocationStatus(rawValue: statusRaw) ?? .scouted,
            isFlagged: isFlagged
        )
    }
}

// MARK: - Script

@MainActor
final class ScriptVM: ObservableObject, Identifiable {
    let id: String
    unowned let s: MacStore
    private var applying = false
    @Published var name: String = "" { didSet { persistChange(applying) { [id, name] in try await ScoutStore.shared.renameScript(id: id, name: name) } } }
    @Published var rawText: String = "" { didSet { persistChange(applying) { [id, rawText] in try await ScoutStore.shared.updateScriptText(id: id, rawText: rawText) } } }
    @Published var sortOrder: Int = 0 { didSet { persistChange(applying) { [id, sortOrder] in try await ScoutStore.shared.setScriptSortOrder(id: id, order: sortOrder) } } }
    var importedAt: Date = Date()
    var updatedAt: Date = Date()
    private(set) var projectId: String?

    init(_ r: ScriptRecord, _ s: MacStore) { self.id = r.id; self.s = s; apply(r) }
    func apply(_ r: ScriptRecord) {
        applying = true; defer { applying = false }
        name = r.name; rawText = r.rawText; sortOrder = r.sortOrder
        importedAt = r.importedAt; updatedAt = r.updatedAt; projectId = r.projectId
    }

    var uuid: UUID { UUID(uuidString: id) ?? UUID() }
    var project: ProjectVM? { s.project(projectId) }
    var highlights: [HighlightVM] { s.highlightsIn(scriptId: id) }
}

// MARK: - Script highlight

@MainActor
final class HighlightVM: ObservableObject, Identifiable {
    let id: String
    unowned let s: MacStore
    @Published var rangeStart: Int = 0
    @Published var rangeLength: Int = 0
    @Published var excerpt: String = ""
    @Published var contextBefore: String = ""
    @Published var contextAfter: String = ""
    @Published var sceneHeading: String?
    var createdAt: Date = Date()
    private(set) var scriptId: String?
    private(set) var listId: String?

    init(_ r: HighlightRecord, _ s: MacStore) { self.id = r.id; self.s = s; apply(r) }
    func apply(_ r: HighlightRecord) {
        rangeStart = r.rangeStart; rangeLength = r.rangeLength; excerpt = r.excerpt
        contextBefore = r.contextBefore; contextAfter = r.contextAfter; sceneHeading = r.sceneHeading
        createdAt = r.createdAt; scriptId = r.scriptId; listId = r.listId
    }

    var uuid: UUID { UUID(uuidString: id) ?? UUID() }
    var script: ScriptVM? { s.script(scriptId) }
    var list: ListVM? { s.list(listId) }
}
