import SwiftUI
import CoreData
import CloudKit
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

/// Accepts incoming CloudKit share invitations (when the user taps an invite link the OS
/// hands the share metadata to the app delegate). Routes them into the shared store.
#if os(macOS)
final class ScoutAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        PersistenceController.shared.acceptShare(metadata: metadata)
    }
}
#else
/// On iOS the app is scene-based (SwiftUI lifecycle), so the OS delivers an accepted CloudKit
/// share to the SCENE delegate, not the app delegate. We register this scene delegate via
/// `configurationForConnecting` below so opening an invite link actually joins the project.
final class ScoutSceneDelegate: NSObject, UIWindowSceneDelegate {
    // Accept an invite when the app is running or backgrounded. We deliberately do NOT implement
    // scene(_:willConnectTo:) — doing so makes this delegate take over window setup and prevents
    // SwiftUI's WindowGroup from installing its UI (the app launches to a blank screen).
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        PersistenceController.shared.acceptShare(metadata: metadata)
    }
}

final class ScoutAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = ScoutSceneDelegate.self
        return config
    }

    // Fallback for the app-delegate path (some launch scenarios still route here).
    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        PersistenceController.shared.acceptShare(metadata: metadata)
    }
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
                // P2 migration: opt into the PowerSync-backed browse UI with the SCOUT_STORE_UI
                // launch arg. Default stays on the live Core Data tree until the port is verified.
                if ProcessInfo.processInfo.environment["SCOUT_STORE_UI"] != nil {
                    IOSStoreRootView()
                } else {
                    ScoutIOSRootView()
                }
                #else
                ContentView()
                #endif
            } else {
                AuthView()
            }
        }
        // Start/refresh sync whenever the signed-in state changes.
        .task(id: auth.isAuthenticated) {
            if auth.isAuthenticated { await ScoutStore.shared.connectIfPossible() }
        }
    }
}

@main
struct ScoutApp: App {
    @StateObject private var apiKeyState = APIKeyState.shared
    @StateObject private var auth = AuthManager.shared
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ScoutAppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(ScoutAppDelegate.self) private var appDelegate
    #endif

    /// Core Data + CloudKit stack (docs/collaboration-plan.md, Path B). Private CloudKit sync +
    /// a shared store for CKShare collaboration are enabled in PersistenceController.
    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            // No onboarding gate — open straight into the app. The Anthropic key (and any
            // other keys) can be set anytime in Settings; AI features prompt if it's missing.
            RootGate()
            // Always-visible first-time photo download progress, centered at the top under the
            // dynamic island / toolbar.
            .overlay(alignment: .top) { PhotoSyncBar() }
        }
        .environmentObject(apiKeyState)
        .environmentObject(auth)
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
