import SwiftUI

/// Debug tool: dumps EVERY record in the PowerSync store and flags ones not reachable from a live
/// project ("orphans"). Now reads `MacStore` (the store-backed VM graph) instead of Core Data, so
/// it doubles as a way to inspect what's actually in the synced store on the Mac — handy for
/// verifying sync and (later) import. Postgres FKs make true orphans rare, but the reachability
/// pass is kept as a sanity check.
struct DataInspectorView: View {
    @ObservedObject private var mac = MacStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var onlyOrphans = false
    @State private var showDeleteConfirm = false
    @State private var searchText = ""

    private func matches(_ fields: String...) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(q) }
    }

    private struct Reachable {
        var listIDs = Set<String>()
        var pinIDs = Set<String>()
        var scriptIDs = Set<String>()
        var highlightIDs = Set<String>()
        var listInfo: [String: String] = [:]
        var pinInfo: [String: String] = [:]
    }

    /// One pass over the live projects to build reachable id sets + subtitles.
    private func computeReachable() -> Reachable {
        var r = Reachable()
        func walk(_ l: ListVM, project: String, parent: String?) {
            guard r.listIDs.insert(l.id).inserted else { return }
            var info = parent.map { "in folder: \($0)" } ?? "project: \(project)"
            info += " · \(l.pins.count) pins"
            if l.deletedAt != nil { info += " · trashed" }
            r.listInfo[l.id] = info
            for pin in l.pins {
                r.pinIDs.insert(pin.id)
                r.pinInfo[pin.id] = "list: \(l.name)" + (pin.deletedAt != nil ? " · trashed" : "")
            }
            for child in l.childLists { walk(child, project: project, parent: l.name) }
        }
        for p in mac.projects {
            for l in p.lists where l.parentList == nil { walk(l, project: p.name, parent: nil) }
            for pin in p.importedPhotos {
                r.pinIDs.insert(pin.id)
                r.pinInfo[pin.id] = "loose in: \(p.name)" + (pin.deletedAt != nil ? " · trashed" : "")
            }
            for s in p.scripts {
                r.scriptIDs.insert(s.id)
                for h in s.highlights { r.highlightIDs.insert(h.id) }
            }
        }
        return r
    }

    var body: some View {
        let r = computeReachable()
        let orphanLists = mac.lists.filter { !r.listIDs.contains($0.id) }
        let orphanPins = mac.pins.filter { !r.pinIDs.contains($0.id) }
        let orphanScripts = mac.scripts.filter { !r.scriptIDs.contains($0.id) }
        let orphanCount = orphanLists.count + orphanPins.count + orphanScripts.count

        let shownProjects = mac.projects.filter { p in
            matches(p.name, p.id, p.deletedAt != nil ? "trashed" : "")
        }
        let shownLists = (onlyOrphans ? orphanLists : mac.lists).filter { l in
            matches(l.name, r.listInfo[l.id] ?? "", l.id, l.deletedAt != nil ? "trashed" : "")
        }
        let shownPins = (onlyOrphans ? orphanPins : mac.pins).filter { p in
            matches(p.name, r.pinInfo[p.id] ?? "", p.id, p.deletedAt != nil ? "trashed" : "")
        }
        let shownScripts = (onlyOrphans ? orphanScripts : mac.scripts).filter { s in
            matches(s.name, s.id)
        }

        return VStack(spacing: 0) {
            header(orphanCount: orphanCount, orphanLists: orphanLists, orphanPins: orphanPins, orphanScripts: orphanScripts)
            searchBar
            Divider()
            List {
                Section {
                    ForEach(shownProjects) { p in
                        row(title: p.name.isEmpty ? "(untitled)" : p.name,
                            subtitle: "\(p.lists.count) lists · \(p.importedPhotos.count) loose · \(p.scripts.count) scripts",
                            orphan: false, trashed: p.deletedAt != nil)
                    }
                } header: { Text("Projects (\(shownProjects.count))").font(.caption.bold()) }

                Section {
                    ForEach(shownLists) { l in
                        let orphan = !r.listIDs.contains(l.id)
                        row(title: l.name.isEmpty ? "(unnamed list)" : l.name,
                            subtitle: orphan ? "⚠️ no live project (deleted)" : (r.listInfo[l.id] ?? ""),
                            orphan: orphan, trashed: l.deletedAt != nil)
                    }
                } header: { Text("Lists — \(shownLists.count) shown / \(mac.lists.count) total, \(orphanLists.count) orphaned").font(.caption.bold()) }

                Section {
                    ForEach(shownPins) { p in
                        let orphan = !r.pinIDs.contains(p.id)
                        row(title: p.name.isEmpty ? "(unnamed pin)" : p.name,
                            subtitle: orphan ? "⚠️ orphaned" : (r.pinInfo[p.id] ?? ""),
                            orphan: orphan, trashed: p.deletedAt != nil)
                    }
                } header: { Text("Pins — \(shownPins.count) shown / \(mac.pins.count) total, \(orphanPins.count) orphaned").font(.caption.bold()) }

                if !mac.scripts.isEmpty {
                    Section {
                        ForEach(shownScripts) { s in
                            let orphan = !r.scriptIDs.contains(s.id)
                            row(title: s.name, subtitle: orphan ? "⚠️ orphaned" : "\(s.highlights.count) highlights", orphan: orphan, trashed: false)
                        }
                    } header: { Text("Scripts — \(shownScripts.count) shown / \(mac.scripts.count) total, \(orphanScripts.count) orphaned").font(.caption.bold()) }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 640, height: 560)
    }

    private func header(orphanCount: Int, orphanLists: [ListVM], orphanPins: [PinVM], orphanScripts: [ScriptVM]) -> some View {
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
                Button("Delete \(orphanCount) orphans", role: .destructive) {
                    deleteOrphans(lists: orphanLists, pins: orphanPins, scripts: orphanScripts)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These belong to no live project and never appear in the UI. Your visible data is untouched.")
            }
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search by name, metadata, or id…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func row(title: String, subtitle: String, orphan: Bool, trashed: Bool) -> some View {
        HStack(spacing: 8) {
            if trashed {
                Image(systemName: "trash.fill").font(.system(size: 10)).foregroundStyle(.red.opacity(0.8)).help("In the Trash")
            }
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
        .listRowBackground(orphan ? Color.red.opacity(0.08) : (trashed ? Color.red.opacity(0.04) : Color.clear))
    }

    /// Purge orphans through ScoutStore (FK cascade reaches any children on sync).
    private func deleteOrphans(lists: [ListVM], pins: [PinVM], scripts: [ScriptVM]) {
        let listIDs = lists.map(\.id), pinIDs = pins.map(\.id), scriptIDs = scripts.map(\.id)
        Task {
            for id in pinIDs { try? await ScoutStore.shared.execute("DELETE FROM pins WHERE id = ?", [id]) }
            for id in listIDs { try? await ScoutStore.shared.execute("DELETE FROM location_lists WHERE id = ?", [id]) }
            for id in scriptIDs { try? await ScoutStore.shared.deleteScript(id: id) }
        }
    }
}
