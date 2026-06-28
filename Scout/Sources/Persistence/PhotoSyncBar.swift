import SwiftUI

/// Small, always-visible capsule shown while first-time photo downloads are in progress
/// (e.g. right after accepting a shared project). Hidden when nothing is downloading.
/// Add it as a top-level overlay on each platform's root so it's visible in any view.
struct PhotoSyncBar: View {
    @ObservedObject private var progress = PhotoSyncProgress.shared

    var body: some View {
        if progress.isDownloading {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.caption)
                    Text("Downloading photos \(progress.downloaded) / \(progress.total)")
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
            // Centered under the dynamic island (iOS) / top toolbar (macOS).
            .padding(.top, 54)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: progress.isDownloading)
        }
    }
}
