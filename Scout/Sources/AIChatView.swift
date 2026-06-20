import SwiftUI
import ScoutKit

// MARK: - Model options

enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus    = "claude-opus-4-8"
    case sonnet  = "claude-sonnet-4-6"
    case haiku   = "claude-haiku-4-5-20251001"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus:   "Opus 4.8"
        case .sonnet: "Sonnet 4.6"
        case .haiku:  "Haiku 4.5"
        }
    }

    var description: String {
        switch self {
        case .opus:   "Most capable"
        case .sonnet: "Balanced"
        case .haiku:  "Fastest"
        }
    }

    var symbolName: String {
        switch self {
        case .opus:   "sparkles"
        case .sonnet: "bolt"
        case .haiku:  "hare"
        }
    }
}

// MARK: - Message model

enum ChatMessage: Identifiable {
    case user(id: UUID = .init(), text: String)
    case status(id: UUID = .init(), text: String)
    case result(id: UUID = .init(), count: Int)
    case error(id: UUID = .init(), text: String)

    var id: UUID {
        switch self {
        case .user(let id, _):   id
        case .status(let id, _): id
        case .result(let id, _): id
        case .error(let id, _):  id
        }
    }
}

// MARK: - Chat sidebar

struct AIChatView: View {
    @Binding var messages: [ChatMessage]
    var isSearching: Bool
    var onSend: (String, ClaudeModel, Bool) -> Void

    @AppStorage("aiScout.constrainToMap") var constrainToMap = true
    @AppStorage("aiScout.model") private var modelRaw = ClaudeModel.opus.rawValue
    @AppStorage("aiScout.extendedThinking") private var extendedThinking = false
    @State private var inputText = ""
    @FocusState private var focused: Bool
    @EnvironmentObject private var apiKeyState: APIKeyState
    @ObservedObject private var costService = UsageCostService.shared

    private var selectedModel: ClaudeModel {
        ClaudeModel(rawValue: modelRaw) ?? .opus
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            inputBar
            if apiKeyState.anthropicAdminKeyIsSet {
                costFooter
            }
        }
        .task {
            await costService.refresh(adminKey: apiKeyState.anthropicAdminKey)
        }
    }

    // MARK: Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty && !isSearching {
                        emptyPrompt
                    }
                    ForEach(messages) { message in
                        messageBubble(for: message)
                            .id(message.id)
                    }
                    if isSearching {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: isSearching) { _, searching in
                if searching {
                    withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageBubble(for message: ChatMessage) -> some View {
        switch message {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.blue, in: .rect(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            }

        case .status(_, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Spacer()
            }

        case .result(_, let count):
            HStack(spacing: 8) {
                Image(systemName: count > 0 ? "mappin.and.ellipse" : "mappin.slash")
                    .foregroundStyle(count > 0 ? .green : .secondary)
                Text(count > 0 ? "Found \(count) location\(count == 1 ? "" : "s") — check the map" : "No locations found")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(count > 0 ? .primary : .secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: .rect(cornerRadius: 10, style: .continuous))

        case .error(_, let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Describe locations you're looking for")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("e.g. \"Moody industrial buildings in Tokyo\" or \"A beach that looks like the 1960s\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scouting…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Text input + send button
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Describe what you're looking for…")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $inputText)
                        .focused($focused)
                        .frame(minHeight: 60, maxHeight: 140)
                        .scrollContentBackground(.hidden)
                        .onKeyPress(.return) {
                            guard canSend else { return .ignored }
                            send()
                            return .handled
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator, lineWidth: 1))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(canSend ? Color.blue : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.bottom, 6)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Options row
            HStack(spacing: 0) {
                // Model picker
                Menu {
                    ForEach(ClaudeModel.allCases) { model in
                        Button {
                            modelRaw = model.rawValue
                        } label: {
                            HStack {
                                Image(systemName: model.symbolName)
                                VStack(alignment: .leading) {
                                    Text(model.displayName)
                                    Text(model.description).foregroundStyle(.secondary)
                                }
                                if model == selectedModel {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedModel.symbolName)
                            .font(.caption)
                        Text(selectedModel.displayName)
                            .font(.caption.weight(.medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: .capsule)
                }
                .buttonStyle(.plain)

                Spacer()

                // Extended thinking toggle
                if selectedModel == .opus {
                    Toggle(isOn: $extendedThinking) {
                        Label("Think", systemImage: "brain")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(extendedThinking ? .blue : .secondary)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .tint(.blue)
                }

                // Constrain to map toggle
                Toggle(isOn: $constrainToMap) {
                    Label("Map area", systemImage: "map")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(constrainToMap ? .blue : .secondary)
                }
                .toggleStyle(.button)
                .controlSize(.mini)
                .tint(.blue)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: Cost footer

    private var costFooter: some View {
        HStack(spacing: 6) {
            if costService.isLoading {
                ProgressView().controlSize(.mini)
                Text("Updating…")
            } else if let cost = costService.monthlyCost {
                Image(systemName: "dollarsign.circle")
                Text(cost, format: .currency(code: "USD"))
                    .fontWeight(.medium)
                Text("this month")
            } else if costService.error != nil {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("Couldn't load cost")
            }
            Spacer()
            Button {
                Task { await costService.refresh(adminKey: apiKeyState.anthropicAdminKey) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(costService.isLoading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background.secondary)
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSearching
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSearching else { return }
        inputText = ""
        focused = false
        onSend(text, selectedModel, extendedThinking)
    }
}
