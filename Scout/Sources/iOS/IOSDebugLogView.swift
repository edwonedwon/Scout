// IOSDebugLogView.swift — on-device debug log viewer for iOS (the Mac has DebugPanelOverlay).
// Lets you watch photo sync (tag "Photos") and other events run on a detached build, where the
// Xcode console isn't available.

#if os(iOS)
import SwiftUI
import ScoutKit

struct IOSDebugLogView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @Environment(\.dismiss) private var dismiss
    @State private var photosOnly = false

    private var entries: [DebugEntry] {
        photosOnly ? logger.entries.filter { $0.tag == "Photos" } : logger.entries
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Toggle("Photos only", isOn: $photosOnly)
                    .padding(.horizontal).padding(.vertical, 8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(entries) { entry in
                                Text(entry.formatted)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: logger.entries.count) { _, _ in
                        if let last = entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                    .onAppear { if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
                if entries.isEmpty {
                    ContentUnavailableView("No log entries yet", systemImage: "ant",
                                           description: Text("Open a project to watch photo sync run."))
                }
            }
            .navigationTitle("Debug Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { logger.clear() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func color(for level: DebugEntry.Level) -> Color {
        switch level {
        case .info:    return .primary
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        case .network: return .blue
        }
    }
}
#endif
