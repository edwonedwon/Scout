import SwiftUI
import SwiftData

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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var projects: [ProjectData]
    @Query private var lists: [LocationListData]
    @Query private var pins: [PinnedLocationData]
    @Query private var scripts: [ScriptData]
    @Query private var highlights: [ScriptHighlight]

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
                    ForEach(onlyOrphans ? orphanLists : lists, id: \.persistentModelID) { l in
                        let orphan = !r.listIDs.contains(l.persistentModelID)
                        row(title: l.name.isEmpty ? "(unnamed list)" : l.name,
                            subtitle: orphan ? "⚠️ no live project (deleted)" : (r.listInfo[l.persistentModelID] ?? ""),
                            orphan: orphan)
                    }
                } header: { Text("Lists — \(lists.count) total, \(orphanLists.count) orphaned").font(.caption.bold()) }

                Section {
                    ForEach(onlyOrphans ? orphanPins : pins, id: \.persistentModelID) { p in
                        let orphan = !r.pinIDs.contains(p.persistentModelID)
                        row(title: p.name.isEmpty ? "(unnamed pin)" : p.name,
                            subtitle: orphan ? "⚠️ orphaned" : (r.pinInfo[p.persistentModelID] ?? ""),
                            orphan: orphan)
                    }
                } header: { Text("Pins — \(pins.count) total, \(orphanPins.count) orphaned").font(.caption.bold()) }

                if !scripts.isEmpty {
                    Section {
                        ForEach(onlyOrphans ? orphanScripts : scripts, id: \.persistentModelID) { s in
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
        // Delete pins first, then lists (so cascade has nothing dangling to chase). We never read
        // the orphans' .project/.owningProject — only their own id — so no invalidated access.
        for p in pins where !r.pinIDs.contains(p.persistentModelID) { modelContext.delete(p) }
        for l in lists where !r.listIDs.contains(l.persistentModelID) { modelContext.delete(l) }
        for s in scripts where !r.scriptIDs.contains(s.persistentModelID) { modelContext.delete(s) }
        for h in highlights where !r.highlightIDs.contains(h.persistentModelID) { modelContext.delete(h) }
        try? modelContext.save()
    }
}
