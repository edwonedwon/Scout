import SwiftUI
import ScoutKit

struct SettingsView: View {
    @EnvironmentObject private var apiKeyState: APIKeyState
    @State private var anthropicKeyInput = ""
    @State private var googleMapsKeyInput = ""
    @State private var saveError: String?
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                apiKeyRow(
                    label: "Anthropic API Key",
                    placeholder: "sk-ant-...",
                    isSet: apiKeyState.anthropicKeyIsSet,
                    input: $anthropicKeyInput
                )
            } header: {
                Text("AI Search")
            } footer: {
                Text("Required. Powers location search. Get a key at console.anthropic.com")
            }

            Section {
                apiKeyRow(
                    label: "Google Maps API Key",
                    placeholder: "AIza...",
                    isSet: apiKeyState.googleMapsKeyIsSet,
                    input: $googleMapsKeyInput
                )
            } header: {
                Text("Google Maps")
            } footer: {
                Text("Optional. Enables Street View and richer place data.")
            }

            if saveError != nil {
                Section {
                    Text(saveError!)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section {
                Button("Save Keys") { save() }
                    .disabled(anthropicKeyInput.isEmpty && googleMapsKeyInput.isEmpty)

                Button("Clear All Keys", role: .destructive) {
                    showClearConfirm = true
                }
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Clear all saved API keys?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear All Keys", role: .destructive) {
                apiKeyState.clearAll()
                anthropicKeyInput = ""
                googleMapsKeyInput = ""
            }
        }
        .formStyle(.grouped)
    }

    private func apiKeyRow(label: String, placeholder: String, isSet: Bool, input: Binding<String>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if isSet && input.wrappedValue.isEmpty {
                    Text("Key saved")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            SecureField(isSet ? "Update key..." : placeholder, text: input)
                .multilineTextAlignment(.trailing)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .frame(maxWidth: 220)
        }
    }

    private func save() {
        saveError = nil
        do {
            if !anthropicKeyInput.isEmpty {
                try apiKeyState.saveAnthropicKey(anthropicKeyInput)
                anthropicKeyInput = ""
            }
            if !googleMapsKeyInput.isEmpty {
                try apiKeyState.saveGoogleMapsKey(googleMapsKeyInput)
                googleMapsKeyInput = ""
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
