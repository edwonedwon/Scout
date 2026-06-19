import SwiftUI
import ScoutKit

struct SettingsView: View {
    @EnvironmentObject private var apiKeyState: APIKeyState
    @AppStorage("map.scrollToZoom") private var scrollToZoom = false
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                APIKeyField(
                    placeholder: "sk-ant-...",
                    isSet: apiKeyState.anthropicKeyIsSet,
                    onSave: { try apiKeyState.saveAnthropicKey($0) }
                )
            } header: {
                Text("AI Search")
            } footer: {
                Text("Required. Powers AI Scout search. Get a key at console.anthropic.com")
            }

            Section {
                APIKeyField(
                    placeholder: "AIza...",
                    isSet: apiKeyState.googleMapsKeyIsSet,
                    onSave: { try apiKeyState.saveGoogleMapsKey($0) }
                )
            } header: {
                Text("Google Maps")
            } footer: {
                Text("Required for Google Maps search mode.")
            }

            #if os(macOS)
            Section {
                Toggle("Two-finger scroll to zoom", isOn: $scrollToZoom)
            } header: {
                Text("Map")
            } footer: {
                Text("Swipe up/down with two fingers to zoom instead of pinch.")
            }
            #endif

            Section {
                Button("Clear All Keys", role: .destructive) {
                    showClearConfirm = true
                }
            }
        }
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .formStyle(.grouped)
        .confirmationDialog("Clear all saved API keys?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear All Keys", role: .destructive) {
                apiKeyState.clearAll()
            }
        }
    }
}

struct APIKeyField: View {
    let placeholder: String
    let isSet: Bool
    let onSave: (String) throws -> Void

    @State private var input = ""
    @State private var isRevealed = false
    @State private var errorMessage: String?
    @State private var justSaved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Group {
                    if isRevealed {
                        TextField(isSet ? "Update key..." : placeholder, text: $input)
                    } else {
                        SecureField(isSet ? "Update key..." : placeholder, text: $input)
                    }
                }
                .multilineTextAlignment(.leading)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack {
                if justSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if isSet && input.isEmpty {
                    Label("Key saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Save") { save() }
                    .disabled(input.isEmpty)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func save() {
        errorMessage = nil
        do {
            try onSave(input)
            input = ""
            justSaved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                justSaved = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
