// StoreModels.swift — cross-platform observable view-models over ScoutStore (migration plan P2).
//
// These ObservableObjects bridge PowerSync's `watch` streams to SwiftUI. They replace the Core Data
// @FetchRequest + NSManagedObject relationship walks that the Mac (ContentView/ProjectsPanel) and
// iOS view trees were built on. Reads are reactive (the @Published arrays update whenever the local
// SQLite changes, whether from a local write or an incoming sync); writes go straight to ScoutStore.
//
// Used by both platforms so the data layer is defined once.

import Foundation
import Combine

/// Watches every live project plus its list/pin counts — the browse/sidebar project list.
@MainActor
final class ProjectsListModel: ObservableObject {
    @Published var summaries: [ProjectSummary] = []
    private var task: Task<Void, Never>?

    init() {
        task = Task { [weak self] in
            do {
                for try await rows in ScoutStore.shared.watchProjectSummaries() {
                    self?.summaries = rows
                }
            } catch { /* stream cancelled on deinit */ }
        }
    }
    deinit { task?.cancel() }

    var projects: [ProjectRecord] { summaries.map(\.project) }

    @discardableResult
    func create(name: String, notes: String = "") async -> String? {
        try? await ScoutStore.shared.createProject(name: name, notes: notes)
    }
    func rename(_ id: String, to name: String) async { try? await ScoutStore.shared.renameProject(id: id, name: name) }
    func softDelete(_ id: String) async { try? await ScoutStore.shared.softDeleteProject(id: id) }
    func restore(_ id: String) async { try? await ScoutStore.shared.restoreProject(id: id) }
    func purge(_ id: String) async { try? await ScoutStore.shared.purgeProject(id: id) }
}

/// Watches all lists, pins, and scripts for one project, and derives the folder/list/pin tree the
/// sidebar and grid render (replacing the Core Data relationship walks). One model per open project.
@MainActor
final class ProjectTreeModel: ObservableObject {
    let project: ProjectRecord
    @Published var allLists: [ListRecord] = []
    @Published var allPins: [PinRecord] = []
    @Published var scripts: [ScriptRecord] = []
    private var tasks: [Task<Void, Never>] = []

    init(project: ProjectRecord) {
        self.project = project
        let id = project.id
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllLists(projectId: id) { self?.allLists = rows } }
            catch {}
        })
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchAllPins(projectId: id) { self?.allPins = rows } }
            catch {}
        })
        tasks.append(Task { [weak self] in
            do { for try await rows in ScoutStore.shared.watchScripts(projectId: id) { self?.scripts = rows } }
            catch {}
        })
    }
    deinit { tasks.forEach { $0.cancel() } }

    // MARK: - Derived tree (live rows only; ScoutStore's watch queries already exclude deleted_at)

    var topLevelLists: [ListRecord] {
        allLists.filter { $0.parentListId == nil }.sorted { $0.panelOrder < $1.panelOrder }
    }
    func children(of listId: String) -> [ListRecord] {
        allLists.filter { $0.parentListId == listId }.sorted { $0.panelOrder < $1.panelOrder }
    }
    func isFolder(_ listId: String) -> Bool { allLists.contains { $0.parentListId == listId } }
    func list(_ id: String) -> ListRecord? { allLists.first { $0.id == id } }
    func pins(inList listId: String) -> [PinRecord] {
        allPins.filter { $0.listId == listId }.sorted { $0.sortOrder < $1.sortOrder }
    }
    /// Pins a folder rolls up (its own + descendants'), for count badges.
    func rollupPinCount(_ listId: String) -> Int {
        pins(inList: listId).count + children(of: listId).reduce(0) { $0 + rollupPinCount($1.id) }
    }
    /// Loose photos imported straight into the project (no list).
    var loosePhotos: [PinRecord] {
        allPins.filter { $0.listId == nil && $0.owningProjectId == project.id }
            .sorted { $0.panelOrder < $1.panelOrder }
    }
    func colorHex(forList listId: String?) -> String {
        listId.flatMap { id in allLists.first { $0.id == id }?.colorHex } ?? "#FF6B35"
    }
}
