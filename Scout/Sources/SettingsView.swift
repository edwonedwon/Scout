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
                    placeholder: "sk-ant-api...",
                    isSet: apiKeyState.anthropicKeyIsSet,
                    onSave: { try apiKeyState.saveAnthropicKey($0) }
                )
            } header: {
                KeySectionHeader("Anthropic API Key", help: .anthropic)
            }

            Section {
                APIKeyField(
                    placeholder: "sk-ant-admin...",
                    isSet: apiKeyState.anthropicAdminKeyIsSet,
                    onSave: { try apiKeyState.saveAnthropicAdminKey($0) }
                )
            } header: {
                KeySectionHeader("Anthropic Admin Key", help: .anthropicAdmin)
            }

            Section {
                APIKeyField(
                    placeholder: "AIza...",
                    isSet: apiKeyState.googleMapsKeyIsSet,
                    onSave: { try apiKeyState.saveGoogleMapsKey($0) }
                )
            } header: {
                KeySectionHeader("Google Maps", help: .googleMaps)
            }

            Section {
                APIKeyField(
                    placeholder: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
                    isSet: apiKeyState.flickrKeyIsSet,
                    onSave: { try apiKeyState.saveFlickrKey($0) }
                )
            } header: {
                KeySectionHeader("Flickr", help: .flickr)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("No API key required")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let url = URL(string: "https://commons.wikimedia.org") {
                        Link("Open Commons", destination: url)
                            .font(.caption)
                    }
                }
            } header: {
                KeySectionHeader("Wikimedia Commons", help: .wikimedia)
            } footer: {
                Text("Wikimedia Commons is free and open — search millions of geotagged photos with no account needed.")
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

// MARK: - Section header with help popover

struct KeySectionHeader: View {
    let title: String
    let help: KeyHelp

    @State private var showHelp = false

    init(_ title: String, help: KeyHelp) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                KeyHelpPopover(help: help)
            }
        }
    }
}

// MARK: - Help content model

struct KeyHelp {
    let title: String
    let required: Bool
    let summary: String
    let steps: [Step]
    let url: URL?

    struct Step {
        let text: String
        var isCode: Bool = false
    }

    static let anthropic = KeyHelp(
        title: "Anthropic API Key",
        required: true,
        summary: "Powers AI Scout. Required to use any AI search features.",
        steps: [
            .init(text: "Go to console.anthropic.com and sign in"),
            .init(text: "Click Settings → API Keys"),
            .init(text: "Click Create Key and give it a name"),
            .init(text: "Copy the key — it starts with:"),
            .init(text: "sk-ant-api...", isCode: true),
        ],
        url: URL(string: "https://console.anthropic.com/settings/keys")
    )

    static let anthropicAdmin = KeyHelp(
        title: "Anthropic Admin Key",
        required: false,
        summary: "Optional. Lets Scout show your real monthly Claude API spend in the AI Scout panel.",
        steps: [
            .init(text: "Go to console.anthropic.com and sign in"),
            .init(text: "Click Settings → API Keys"),
            .init(text: "Click Create Admin Key (requires org Admin/Owner role)"),
            .init(text: "Copy the key — it starts with:"),
            .init(text: "sk-ant-admin...", isCode: true),
            .init(text: "Note: only org admins can create admin keys"),
        ],
        url: URL(string: "https://console.anthropic.com/settings/keys")
    )

    static let googleMaps = KeyHelp(
        title: "Google Maps API Key",
        required: true,
        summary: "Powers the Google Maps location search in the left panel.",
        steps: [
            .init(text: "Go to console.cloud.google.com"),
            .init(text: "Create or select a project"),
            .init(text: "Go to APIs & Services → Library"),
            .init(text: "Enable Places API (New)"),
            .init(text: "Go to APIs & Services → Credentials"),
            .init(text: "Click Create Credentials → API Key"),
            .init(text: "Restrict the key to Places API for security"),
        ],
        url: URL(string: "https://console.cloud.google.com/apis/credentials")
    )

    static let wikimedia = KeyHelp(
        title: "Wikimedia Commons",
        required: false,
        summary: "Free photo search — no account or API key needed. Commons hosts millions of freely licensed, geotagged photos uploaded by Wikipedia contributors worldwide.",
        steps: [
            .init(text: "No setup required"),
            .init(text: "Just select \"Wiki\" in the search toggle and start searching"),
            .init(text: "Results are filtered to geotagged photos only"),
            .init(text: "Photos are free to use under Creative Commons licenses"),
        ],
        url: URL(string: "https://commons.wikimedia.org")
    )

    static let flickr = KeyHelp(
        title: "Flickr API Key",
        required: false,
        summary: "Powers Flickr photo search — finds real geotagged photos near locations.",
        steps: [
            .init(text: "Go to flickr.com/services/api/keys"),
            .init(text: "Sign in with a Flickr (Yahoo) account"),
            .init(text: "Click Apply for a Non-Commercial Key"),
            .init(text: "Fill in the app name and description"),
            .init(text: "Copy the Key (not the secret) — it's 32 characters"),
        ],
        url: URL(string: "https://www.flickr.com/services/api/keys/apply/")
    )
}

// MARK: - Help popover view

struct KeyHelpPopover: View {
    let help: KeyHelp

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(help.title)
                        .font(.headline)
                    Label(help.required ? "Required" : "Optional", systemImage: help.required ? "exclamationmark.circle.fill" : "checkmark.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(help.required ? .orange : .secondary)
                }
                Spacer()
            }

            Divider()

            Text(help.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Steps
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(help.steps.enumerated()), id: \.offset) { idx, step in
                    if step.isCode {
                        Text(step.text)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: .rect(cornerRadius: 5))
                            .padding(.leading, 20)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1 - help.steps.prefix(idx).filter(\.isCode).count)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .trailing)
                            Text(step.text)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // Link button
            if let url = help.url {
                Divider()
                Link(destination: url) {
                    Label("Open in browser", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - API key field

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { justSaved = false }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
