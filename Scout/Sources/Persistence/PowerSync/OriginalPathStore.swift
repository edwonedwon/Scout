import Foundation

/// Local-only map of **pin id → absolute path of its original camera file on THIS device**.
///
/// Original file paths are machine-specific, so they deliberately never travel through PowerSync
/// (only the device-independent `original_filename` does). This restores the "open the original"
/// carousel affordance after a relink without polluting the synced schema. Persisted as a small
/// JSON file in Application Support so the link survives relaunches, matching the old Core Data
/// `originalFilePath` attribute.
@MainActor
final class OriginalPathStore {
    static let shared = OriginalPathStore()

    private var map: [String: String] = [:]
    private let fileURL: URL

    init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        #if DEBUG
        fileURL = base.appendingPathComponent("scout-original-paths-dev.json")
        #else
        fileURL = base.appendingPathComponent("scout-original-paths.json")
        #endif
        load()
    }

    func path(for pinId: String) -> String? { map[pinId] }

    func set(_ path: String?, for pinId: String) {
        if let path { map[pinId] = path } else { map.removeValue(forKey: pinId) }
        save()
    }

    /// Bulk-apply (e.g. after a relink run) with a single write.
    func merge(_ entries: [String: String]) {
        guard !entries.isEmpty else { return }
        for (k, v) in entries { map[k] = v }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        map = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
