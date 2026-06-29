import SwiftUI

/// Observable photo-download progress for the always-visible sync bar. Driven by the photo
/// download flow (e.g. Supabase Storage prefetch); idle (`isDownloading == false`) when nothing
/// is in flight, which hides the bar.
/// True while a photo import is running, so the periodic "upload all photos" check pauses — its
/// global count (e.g. 1600+) would otherwise pop up over the import and look like the import's own
/// progress.
@MainActor enum PhotoImportActivity { static var isImporting = false }

@MainActor
final class PhotoSyncProgress: ObservableObject {
    static let shared = PhotoSyncProgress()
    @Published private(set) var downloaded = 0
    @Published private(set) var total = 0
    /// "Downloading" (iOS pull) or "Uploading" (Mac push) — shown in the bar label.
    @Published private(set) var verb = "Downloading"

    var isDownloading: Bool { total > 0 && downloaded < total }
    var fraction: Double { total > 0 ? Double(downloaded) / Double(total) : 0 }

    func update(downloaded: Int, total: Int, verb: String = "Downloading") {
        self.downloaded = downloaded
        self.total = total
        self.verb = verb
    }
}

/// Small, always-visible capsule shown while first-time photo downloads are in progress
/// (e.g. right after accepting a shared project). Hidden when nothing is downloading.
/// Add it as a top-level overlay on each platform's root so it's visible in any view.
struct PhotoSyncBar: View {
    @ObservedObject private var progress = PhotoSyncProgress.shared

    var body: some View {
        if progress.isDownloading {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: progress.verb == "Uploading" ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                        .font(.caption)
                    Text("\(progress.verb) photos \(progress.downloaded) / \(progress.total)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                }
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 8, y: 2)
            // Position is decided by the caller (it's shown only in the map + photo grid).
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: progress.isDownloading)
        }
    }
}
