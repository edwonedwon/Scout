import SwiftUI
import CloudKit
#if os(macOS)
import AppKit
#endif

/// Reliable, self-contained project sharing: creates/configures the project's CKShare, sets the
/// link permission (editor/viewer), persists it to CloudKit, and shows a copyable invite link.
/// No dependency on the AppKit sharing picker — the owner copies the link and sends it however
/// they like; the recipient opens it and the app's accept handler joins them to the project.
struct ProjectShareSheet: View {
    let project: ProjectData
    let onDismiss: () -> Void

    enum Phase: Equatable {
        case preparing
        case ready(URL)
        case failed(String)
    }
    @State private var phase: Phase = .preparing
    @State private var editor = true
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill").font(.title3).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Share Project").font(.headline)
                    Text(project.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Permission", selection: $editor) {
                Text("Can edit").tag(true)
                Text("View only").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: editor) { _, _ in regenerate() }

            Group {
                switch phase {
                case .preparing:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Preparing invite link…").font(.caption).foregroundStyle(.secondary)
                    }
                case .ready(let url):
                    VStack(alignment: .leading, spacing: 8) {
                        Text("INVITE LINK").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Button { copy(url) } label: {
                            Label(copied ? "Copied!" : "Copy Link",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Text("Send this link to the person you want to add. They need the app and must be signed into iCloud; opening the link joins them to this project.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                case .failed(let msg):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't create invite", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                        Text(msg).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { regenerate() }.buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { regenerate() }
    }

    private func regenerate() {
        phase = .preparing
        copied = false
        let editor = editor
        Task {
            // The first attempt can fail fast if CloudKit isn't ready yet (the project record is
            // still exporting). Retry a couple of times before surfacing an error.
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    let url = try await PersistenceController.shared.makeShareLink(for: project, editor: editor)
                    await MainActor.run { phase = .ready(url) }
                    return
                } catch {
                    lastError = error
                    if attempt < 3 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
                }
            }
            await MainActor.run { phase = .failed(lastError?.localizedDescription ?? "Unknown error") }
        }
    }

    private func copy(_ url: URL) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.string = url.absoluteString
        #endif
        copied = true
    }
}
