import SwiftUI
import SwiftData
import ScoutKit

extension Notification.Name {
    static let scoutExportBackup    = Notification.Name("scout.exportBackup")
    static let scoutImportBackup    = Notification.Name("scout.importBackup")
    static let scoutRelinkOriginals = Notification.Name("scout.relinkOriginals")
}

#if os(macOS)
/// Reads openProjectUUID from AppStorage so the Export menu item disables itself
/// automatically when no project is open — commands run outside the view hierarchy.
private struct ExportProjectCommand: View {
    @AppStorage("nav.openProjectUUID") private var openProjectUUID: String = ""
    var body: some View {
        Button("Export Project Data…") {
            NotificationCenter.default.post(name: .scoutExportBackup, object: nil)
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(openProjectUUID.isEmpty)
    }
}

private struct RelinkProjectCommand: View {
    @AppStorage("nav.openProjectUUID") private var openProjectUUID: String = ""
    var body: some View {
        Button("Relink Original Files…") {
            NotificationCenter.default.post(name: .scoutRelinkOriginals, object: nil)
        }
        .disabled(openProjectUUID.isEmpty)
    }
}
#endif

@main
struct ScoutApp: App {
    @StateObject private var apiKeyState = APIKeyState.shared

    /// Local-only store. Once the iCloud/CloudKit entitlement is present, SwiftData's default
    /// `.modelContainer(for:)` AUTO-enables CloudKit — but the current model isn't CloudKit-
    /// compatible (cascade delete rules, non-optional attributes), so the container failed to open
    /// the existing store and the app launched empty. Pin `cloudKitDatabase: .none` to keep using
    /// the local store until the deliberate Core Data + CloudKit migration (docs/collaboration-plan.md).
    private let modelContainer: ModelContainer = {
        let schema = Schema([ProjectData.self, LocationListData.self, PinnedLocationData.self,
                             ScriptData.self, ScriptHighlight.self])
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            // No onboarding gate — open straight into the app. The Anthropic key (and any
            // other keys) can be set anytime in Settings; AI features prompt if it's missing.
            ContentView()
        }
        .environmentObject(apiKeyState)
        .modelContainer(modelContainer)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
        .commands {
            #if os(macOS)
            CommandGroup(after: .newItem) {
                Divider()
                ExportProjectCommand()
                Button("Import Project Data…") {
                    NotificationCenter.default.post(name: .scoutImportBackup, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                RelinkProjectCommand()
                Divider()
            }
            #endif
        }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(apiKeyState)
        }
        #endif
    }
}
