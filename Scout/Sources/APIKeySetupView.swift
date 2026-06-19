import SwiftUI
import ScoutKit

struct APIKeySetupView: View {
    @EnvironmentObject private var apiKeyState: APIKeyState
    @State private var keyInput = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text("Welcome to Scout")
                    .font(.largeTitle.bold())
                Text("Add your Anthropic API key to start finding locations.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Anthropic API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("sk-ant-...", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("Get a key at [console.anthropic.com](https://console.anthropic.com). Stored securely in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 400)

            Button("Continue") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(keyInput.isEmpty)

            Spacer()
        }
        .padding(32)
        .onAppear { fieldFocused = true }
    }

    private func save() {
        do {
            try apiKeyState.saveAnthropicKey(keyInput)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
