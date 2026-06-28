import Foundation

/// Remembers which photo files have already been pushed to Supabase Storage, so the Mac's periodic
/// "are all photos uploaded?" check can skip them and only send new/missing ones (instead of
/// re-uploading everything every launch). Keyed by "tier/filename" — filenames are unique UUIDs but
/// a separate file exists per tier (thumbnail vs full). Persisted as JSON in Application Support;
/// losing it is harmless (uploads are idempotent upserts, the next pass just re-checks).
///
/// Thread-safe via a lock; the upload pass marks entries as it goes and saves once at the end.
final class PhotoUploadLedger: @unchecked Sendable {
    static let shared = PhotoUploadLedger()

    private let lock = NSLock()
    private var keys: Set<String>
    private let fileURL: URL

    init() {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("photo-upload-ledger.json")
        keys = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: fileURL))) ?? []
    }

    private static func key(_ tier: String, _ filename: String) -> String { "\(tier)/\(filename)" }

    func contains(tier: String, filename: String) -> Bool {
        lock.withLock { keys.contains(Self.key(tier, filename)) }
    }

    func mark(tier: String, filename: String) {
        lock.withLock { _ = keys.insert(Self.key(tier, filename)) }
    }

    /// Persist the current set to disk. Called once at the end of an upload pass.
    func save() {
        let snapshot = lock.withLock { keys }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: fileURL) }
    }
}
