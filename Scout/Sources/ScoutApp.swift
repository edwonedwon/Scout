import SwiftUI
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

#if os(macOS)
/// Persists the main window's size/position across launches AND rebuilds. SwiftUI's default
/// WindowGroup restoration relies on macOS "Saved Application State", which the system discards
/// whenever the app binary changes — so every Xcode build reopened the window at the default size.
/// A `frameAutosaveName` stores the frame in `NSUserDefaults` instead, which survives rebuilds.
private struct WindowFrameAutosaver: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let window = v?.window else { return }
            window.setFrameAutosaveName(name)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

/// Auth gate: shows the login screen until the user is signed in, then the app. When Supabase
/// isn't configured yet (`authDisabled`), it falls straight through to the app (local-only mode),
/// so the build is never blocked on account setup.
private struct RootGate: View {
    @EnvironmentObject private var auth: AuthManager
    var body: some View {
        Group {
            if auth.isAuthenticated {
                #if os(iOS)
                // iOS browse UI is now PowerSync-backed (ScoutIOSRootView reads the store VMs).
                ScoutIOSRootView()
                #else
                ContentView()
                #endif
            } else {
                AuthView()
            }
        }
        // Start/refresh sync whenever the signed-in state changes.
        .task(id: auth.isAuthenticated) {
            if auth.isAuthenticated {
                SyncStatusModel.shared.start()
                await ScoutStore.shared.connectIfPossible()
                #if DEBUG
                // End-to-end sync proof: launch a signed-in build with SCOUT_SYNC_SMOKE set.
                if ProcessInfo.processInfo.environment["SCOUT_SYNC_SMOKE"] != nil {
                    await SyncSmokeTest.run()
                }
                #endif
            }
        }
        // NOTE: no scenePhase auto-reconnect. Calling db.connect() again while the live watch
        // streams are mid-flight disrupted them and blanked the UI. PowerSync auto-reconnects its
        // own streaming connection; the sync pill offers a manual reconnect if ever needed.
    }
}

@main
struct ScoutApp: App {
    @StateObject private var apiKeyState = APIKeyState.shared
    @StateObject private var auth = AuthManager.shared

    var body: some Scene {
        WindowGroup {
            // No onboarding gate — open straight into the app. The Anthropic key (and any
            // other keys) can be set anytime in Settings; AI features prompt if it's missing.
            RootGate()
            // Always-visible first-time photo download progress, centered at the top under the
            // dynamic island / toolbar.
            .overlay(alignment: .top) { PhotoSyncBar() }
            #if os(macOS)
            // Remember window size/position across launches and rebuilds.
            .background(WindowFrameAutosaver(name: "ScoutMainWindow"))
            #endif
        }
        .environmentObject(apiKeyState)
        .environmentObject(auth)
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
