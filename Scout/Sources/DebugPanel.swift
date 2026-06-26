import SwiftUI
import ScoutKit

struct DebugPanelOverlay: View {
    var onDeleteAllData: (() -> Void)? = nil
    var onFindDuplicates: (() -> Void)? = nil
    @ObservedObject private var logger = DebugLogger.shared
    @State private var isExpanded = false
    @State private var showDeleteConfirm = false
    @State private var showInspector = false
    // Left-sidebar resize limits — same AppStorage keys ContentView reads.
    @AppStorage("debug.sidebarMinWidth") private var sidebarMinWidth: Double = 200
    @AppStorage("debug.sidebarMaxWidth") private var sidebarMaxWidth: Double = 480

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toggleButton
            if isExpanded {
                panel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.25), value: isExpanded)
    }

    private var toggleButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ant.fill")
                if !logger.entries.isEmpty {
                    Text("\(logger.entries.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Debug Log")
                    .font(.caption.bold())
                Spacer()
                Button {
                    showInspector = true
                } label: {
                    Text("Data Inspector")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .sheet(isPresented: $showInspector) { DataInspectorView() }
                if let findDuplicates = onFindDuplicates {
                    Button {
                        findDuplicates()
                    } label: {
                        Text("Find Duplicates")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                }
                if let deleteAll = onDeleteAllData {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Text("Delete All Data")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .confirmationDialog("Delete all projects, lists, and pins?",
                                        isPresented: $showDeleteConfirm,
                                        titleVisibility: .visible) {
                        Button("Delete All Data", role: .destructive) { deleteAll() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
                Button {
                    logger.clear()
                } label: {
                    Text("Clear Log")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            // Sidebar width limits
            HStack(spacing: 12) {
                Text("Sidebar width")
                    .font(.caption.bold())
                Stepper(value: $sidebarMinWidth, in: 120...sidebarMaxWidth, step: 10) {
                    Text("Min \(Int(sidebarMinWidth))")
                        .font(.system(size: 10, design: .monospaced))
                }
                Stepper(value: $sidebarMaxWidth, in: sidebarMinWidth...900, step: 10) {
                    Text("Max \(Int(sidebarMaxWidth))")
                        .font(.system(size: 10, design: .monospaced))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(logger.entries) { entry in
                            Text(entry.formatted)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: logger.entries.count) { _, _ in
                    if let last = logger.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 420, height: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
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

#if DEBUG
#Preview("Debug panel") {
    DebugPanelOverlay(onDeleteAllData: {})
        .padding()
        .frame(width: 500, height: 320, alignment: .topLeading)
}
#endif
