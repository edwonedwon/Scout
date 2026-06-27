import SwiftUI
import CoreData

/// Debug tool: dumps EVERY record in the store and flags the ones that aren't reachable from a
/// live project (i.e. exist in the data but never show in the UI — "orphans", e.g. lists/pins left
/// behind by a deleted project). Compare against the sidebar, then delete the orphans.
///
/// CRASH-SAFETY: a deleted project leaves dangling to-one references on its orphans
/// (`list.project`, `pin.owningProject`). Reading an invalidated SwiftData instance hard-crashes
/// ("backing data could no longer be found in the store"). So we do ALL relationship traversal in
/// a single pass over the LIVE project graph (every object there is valid) to build reachable-id
/// sets + display strings, then classify each record by ID membership only. We never dereference
/// an individual record's own to-one relationship.
struct DataInspectorView: View {
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @FetchRequest(sortDescriptors: []) private var projects: FetchedResults<ProjectData>
    @FetchRequest(sortDescriptors: []) private var lists: FetchedResults<LocationListData>
    @FetchRequest(sortDescriptors: []) private var pins: FetchedResults<PinnedLocationData>
    @FetchRequest(sortDescriptors: []) private var scripts: FetchedResults<ScriptData>
    @FetchRequest(sortDescriptors: []) private var highlights: FetchedResults<ScriptHighlight>

    @State private var onlyOrphans = false
    @State private var showDeleteConfirm = false

    private struct Reachable {
        var listIDs = Set<PersistentIdentifier>()
        var pinIDs = Set<PersistentIdentifier>()
        var scriptIDs = Set<PersistentIdentifier>()
        var highlightIDs = Set<PersistentIdentifier>()
        var listInfo: [PersistentIdentifier: String] = [:]
        var pinInfo: [PersistentIdentifier: String] = [:]
    }

    /// One safe traversal of the live projects (all valid). Builds reachable sets + subtitles.
    private func computeReachable() -> Reachable {
        var r = Reachable()
        func walk(_ l: LocationListData, project: String, parent: String?) {
            guard r.listIDs.insert(l.persistentModelID).inserted else { return }
            var info = parent.map { "in folder: \($0)" } ?? "project: \(project)"
            info += " · \(l.pins.count) pins"
            if l.deletedAt != nil { info += " · trashed" }
            r.listInfo[l.persistentModelID] = info
            for pin in l.pins {
                r.pinIDs.insert(pin.persistentModelID)
                r.pinInfo[pin.persistentModelID] = "list: \(l.name)" + (pin.deletedAt != nil ? " · trashed" : "")
            }
            for child in l.childLists { walk(child, project: project, parent: l.name) }
        }
        for p in projects {
            for l in p.lists where l.parentList == nil { walk(l, project: p.name, parent: nil) }
            for pin in p.importedPhotos {
                r.pinIDs.insert(pin.persistentModelID)
                r.pinInfo[pin.persistentModelID] = "loose in: \(p.name)" + (pin.deletedAt != nil ? " · trashed" : "")
            }
            for s in p.scripts {
                r.scriptIDs.insert(s.persistentModelID)
                for h in s.highlights { r.highlightIDs.insert(h.persistentModelID) }
            }
        }
        return r
    }

    var body: some View {
        let r = computeReachable()
        let orphanLists = lists.filter { !r.listIDs.contains($0.persistentModelID) }
        let orphanPins = pins.filter { !r.pinIDs.contains($0.persistentModelID) }
        let orphanScripts = scripts.filter { !r.scriptIDs.contains($0.persistentModelID) }
        let orphanCount = orphanLists.count + orphanPins.count + orphanScripts.count

        return VStack(spacing: 0) {
            header(orphanCount: orphanCount, reachable: r)
            Divider()
            List {
                Section {
                    ForEach(projects, id: \.persistentModelID) { p in
                        row(title: p.name.isEmpty ? "(untitled)" : p.name,
                            subtitle: "\(p.lists.count) lists · \(p.importedPhotos.count) loose · \(p.scripts.count) scripts",
                            orphan: false)
                    }
                } header: { Text("Projects (\(projects.count))").font(.caption.bold()) }

                Section {
                    ForEach(onlyOrphans ? orphanLists : Array(lists), id: \.persistentModelID) { l in
                        let orphan = !r.listIDs.contains(l.persistentModelID)
                        row(title: l.name.isEmpty ? "(unnamed list)" : l.name,
                            subtitle: orphan ? "⚠️ no live project (deleted)" : (r.listInfo[l.persistentModelID] ?? ""),
                            orphan: orphan)
                    }
                } header: { Text("Lists — \(lists.count) total, \(orphanLists.count) orphaned").font(.caption.bold()) }

                Section {
                    ForEach(onlyOrphans ? orphanPins : Array(pins), id: \.persistentModelID) { p in
                        let orphan = !r.pinIDs.contains(p.persistentModelID)
                        row(title: p.name.isEmpty ? "(unnamed pin)" : p.name,
                            subtitle: orphan ? "⚠️ orphaned" : (r.pinInfo[p.persistentModelID] ?? ""),
                            orphan: orphan)
                    }
                } header: { Text("Pins — \(pins.count) total, \(orphanPins.count) orphaned").font(.caption.bold()) }

                if !scripts.isEmpty {
                    Section {
                        ForEach(onlyOrphans ? orphanScripts : Array(scripts), id: \.persistentModelID) { s in
                            let orphan = !r.scriptIDs.contains(s.persistentModelID)
                            row(title: s.name, subtitle: orphan ? "⚠️ orphaned" : "\(s.highlights.count) highlights", orphan: orphan)
                        }
                    } header: { Text("Scripts — \(scripts.count) total, \(orphanScripts.count) orphaned").font(.caption.bold()) }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 640, height: 560)
    }

    private func header(orphanCount: Int, reachable r: Reachable) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Data Inspector").font(.headline)
                Text("\(orphanCount) orphaned record(s) — in the store but not shown anywhere in the app")
                    .font(.caption).foregroundStyle(orphanCount > 0 ? .orange : .secondary)
            }
            Spacer()
            Toggle("Only orphans", isOn: $onlyOrphans).toggleStyle(.switch).controlSize(.small)
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Text("Delete \(orphanCount) orphan\(orphanCount == 1 ? "" : "s")")
            }
            .disabled(orphanCount == 0)
            .confirmationDialog("Permanently delete \(orphanCount) orphaned record(s)?",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete \(orphanCount) orphans", role: .destructive) { deleteOrphans(reachable: r) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These belong to no live project and never appear in the UI. Your visible data is untouched.")
            }
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private func row(title: String, subtitle: String, orphan: Bool) -> some View {
        HStack(spacing: 8) {
            if orphan {
                Text("ORPHAN").font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.red.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .listRowBackground(orphan ? Color.red.opacity(0.08) : Color.clear)
    }

    private func deleteOrphans(reachable r: Reachable) {
        // Per-object delete makes Core Data read each orphan's .project to fix up the inverse —
        // which faults on the DELETED project and crashes. Instead, collect the orphans' OWN
        // uuids (safe — their own attribute) and BATCH delete by uuid. NSBatchDeleteRequest runs
        // as a store-level SQL delete: it never materializes the objects or their relationships,
        // so the dangling project is never touched. We merge the deleted ids back so the
        // @FetchRequest results refresh.
        let listUUIDs = lists.filter { !r.listIDs.contains($0.persistentModelID) }.map(\.uuid)
        let pinUUIDs = pins.filter { !r.pinIDs.contains($0.persistentModelID) }.map(\.uuid)
        let scriptUUIDs = scripts.filter { !r.scriptIDs.contains($0.persistentModelID) }.map(\.uuid)
        let highlightUUIDs = highlights.filter { !r.highlightIDs.contains($0.persistentModelID) }.map(\.uuid)
        do {
            try batchDeleteByUUID(PinnedLocationData.self, uuids: pinUUIDs)
            try batchDeleteByUUID(LocationListData.self, uuids: listUUIDs)
            try batchDeleteByUUID(ScriptData.self, uuids: scriptUUIDs)
            try batchDeleteByUUID(ScriptHighlight.self, uuids: highlightUUIDs)
            try modelContext.save()
        } catch {
            print("Orphan cleanup failed: \(error)")
        }
    }

    /// Store-level delete of `type` rows whose `uuidRaw` is in `uuids`, merging the result so
    /// live @FetchRequests refresh. No-op for an empty id list.
    private func batchDeleteByUUID<T: NSManagedObject>(_ type: T.Type, uuids: [UUID]) throws {
        guard !uuids.isEmpty else { return }
        let req = NSFetchRequest<NSFetchRequestResult>(entityName: String(describing: T.self))
        req.predicate = NSPredicate(format: "uuidRaw IN %@", uuids)
        let delete = NSBatchDeleteRequest(fetchRequest: req)
        delete.resultType = .resultTypeObjectIDs
        let result = try modelContext.execute(delete) as? NSBatchDeleteResult
        if let ids = result?.result as? [NSManagedObjectID], !ids.isEmpty {
            NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSDeletedObjectsKey: ids],
                                                into: [modelContext])
        }
    }
}
