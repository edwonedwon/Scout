import SwiftUI
import CoreData
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

    /// Core Data + CloudKit stack (docs/collaboration-plan.md, Path B). CloudKit sync is currently
    /// OFF inside PersistenceController (TODO plan 1f) — this is a local Core Data store for now.
    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            // No onboarding gate — open straight into the app. The Anthropic key (and any
            // other keys) can be set anytime in Settings; AI features prompt if it's missing.
            #if os(iOS)
            ScoutIOSRootView()
            #else
            ContentView()
            #endif
        }
        .environmentObject(apiKeyState)
        .environment(\.managedObjectContext, persistence.viewContext)
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
