import SwiftUI
import SwiftData

/// Debug tool: dumps EVERY record in the store and flags the ones that aren't reachable from a
/// live project (i.e. exist in the data but never show in the UI — "orphans", e.g. lists/pins left
/// behind by a deleted project). Compare against what you see in the sidebar, then delete the
/// orphans. Read-only except for the explicit "Delete orphans" action.
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

    // MARK: - Reachability (what the UI actually shows)

    /// Lists reachable from a live project (walking childLists), keyed by id.
    private var liveListIDs: Set<PersistentIdentifier> {
        var ids = Set<PersistentIdentifier>()
        func walk(_ ls: [LocationListData]) { for l in ls { if ids.insert(l.persistentModelID).inserted { walk(l.childLists) } } }
        for p in projects { walk(p.lists) }
        return ids
    }
    private var livePinIDs: Set<PersistentIdentifier> {
        let liveLists = liveListIDs
        var ids = Set<PersistentIdentifier>()
        for p in projects { for pin in p.importedPhotos { ids.insert(pin.persistentModelID) } }
        for l in lists where liveLists.contains(l.persistentModelID) {
            for pin in l.pins { ids.insert(pin.persistentModelID) }
        }
        return ids
    }
    private var liveScriptIDs: Set<PersistentIdentifier> { Set(projects.flatMap(\.scripts).map(\.persistentModelID)) }
    private var liveHighlightIDs: Set<PersistentIdentifier> { Set(projects.flatMap(\.scripts).flatMap(\.highlights).map(\.persistentModelID)) }

    private func isOrphanList(_ l: LocationListData) -> Bool { !liveListIDs.contains(l.persistentModelID) }
    private func isOrphanPin(_ p: PinnedLocationData) -> Bool { !livePinIDs.contains(p.persistentModelID) }
    private func isOrphanScript(_ s: ScriptData) -> Bool { !liveScriptIDs.contains(s.persistentModelID) }
    private func isOrphanHighlight(_ h: ScriptHighlight) -> Bool { !liveHighlightIDs.contains(h.persistentModelID) }

    private var orphanCount: Int {
        lists.filter(isOrphanList).count + pins.filter(isOrphanPin).count
            + scripts.filter(isOrphanScript).count + highlights.filter(isOrphanHighlight).count
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                section("Projects (\(projects.count))") {
                    ForEach(projects, id: \.persistentModelID) { p in
                        row(title: p.name.isEmpty ? "(untitled)" : p.name,
                            subtitle: "\(p.lists.count) lists · \(p.importedPhotos.count) loose photos · \(p.scripts.count) scripts",
                            orphan: false)
                    }
                }
                let shownLists = lists.filter { !onlyOrphans || isOrphanList($0) }
                section("Lists — \(lists.count) total, \(lists.filter(isOrphanList).count) orphaned") {
                    ForEach(shownLists, id: \.persistentModelID) { l in
                        row(title: l.name.isEmpty ? "(unnamed list)" : l.name,
                            subtitle: listSubtitle(l),
                            orphan: isOrphanList(l))
                    }
                }
                let shownPins = pins.filter { !onlyOrphans || isOrphanPin($0) }
                section("Pins — \(pins.count) total, \(pins.filter(isOrphanPin).count) orphaned") {
                    ForEach(shownPins, id: \.persistentModelID) { p in
                        row(title: p.name.isEmpty ? "(unnamed pin)" : p.name,
                            subtitle: pinSubtitle(p),
                            orphan: isOrphanPin(p))
                    }
                }
                if !scripts.isEmpty {
                    section("Scripts — \(scripts.count) total, \(scripts.filter(isOrphanScript).count) orphaned") {
                        ForEach(scripts.filter { !onlyOrphans || isOrphanScript($0) }, id: \.persistentModelID) { s in
                            row(title: s.name, subtitle: "\(s.highlights.count) highlights", orphan: isOrphanScript(s))
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 640, height: 560)
    }

    private var header: some View {
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
                Button("Delete \(orphanCount) orphans", role: .destructive) { deleteOrphans() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("These belong to no live project and never appear in the UI. Your visible data is untouched.")
            }
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Section { content() } header: { Text(title).font(.caption.bold()) }
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

    private func listSubtitle(_ l: LocationListData) -> String {
        var parts: [String] = []
        if let parent = l.parentList { parts.append("in folder: \(parent.name)") }
        else if let proj = l.project { parts.append("project: \(proj.name)") }
        else { parts.append("⚠️ no project") }
        parts.append("\(l.pins.count) pins")
        if l.deletedAt != nil { parts.append("trashed") }
        return parts.joined(separator: " · ")
    }

    private func pinSubtitle(_ p: PinnedLocationData) -> String {
        var parts: [String] = []
        if let l = p.list { parts.append("list: \(l.name)") }
        else if let proj = p.owningProject { parts.append("loose in: \(proj.name)") }
        else { parts.append("⚠️ no list/project") }
        if p.deletedAt != nil { parts.append("trashed") }
        return parts.joined(separator: " · ")
    }

    private func deleteOrphans() {
        for p in pins where isOrphanPin(p) { modelContext.delete(p) }
        for l in lists where isOrphanList(l) { modelContext.delete(l) }
        for s in scripts where isOrphanScript(s) { modelContext.delete(s) }
        for h in highlights where isOrphanHighlight(h) { modelContext.delete(h) }
        try? modelContext.save()
    }
}
