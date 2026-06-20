import SwiftUI
import ScoutKit

@main
struct ScoutApp: App {
    @StateObject private var apiKeyState = APIKeyState.shared

    var body: some Scene {
        WindowGroup {
            if apiKeyState.anthropicKeyIsSet {
                ContentView()
            } else {
                APIKeySetupView()
            }
        }
        .environmentObject(apiKeyState)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(apiKeyState)
        }
        #endif
    }
}
