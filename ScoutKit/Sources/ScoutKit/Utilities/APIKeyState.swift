import Foundation
import Combine

/// Observable state for the user's API keys. Bind this to your Settings view.
@MainActor
public final class APIKeyState: ObservableObject {
    public static let shared = APIKeyState()

    @Published public var anthropicKey: String = ""
    @Published public var googleMapsKey: String = ""

    public var anthropicKeyIsSet: Bool { !anthropicKey.isEmpty }
    public var googleMapsKeyIsSet: Bool { !googleMapsKey.isEmpty }

    private init() {
        anthropicKey = KeychainService.load(forKey: KeychainService.anthropicAPIKey) ?? ""
        googleMapsKey = KeychainService.load(forKey: KeychainService.googleMapsAPIKey) ?? ""
    }

    public func saveAnthropicKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            KeychainService.delete(forKey: KeychainService.anthropicAPIKey)
            anthropicKey = ""
        } else {
            try KeychainService.save(trimmed, forKey: KeychainService.anthropicAPIKey)
            anthropicKey = trimmed
        }
    }

    public func saveGoogleMapsKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            KeychainService.delete(forKey: KeychainService.googleMapsAPIKey)
            googleMapsKey = ""
        } else {
            try KeychainService.save(trimmed, forKey: KeychainService.googleMapsAPIKey)
            googleMapsKey = trimmed
        }
    }

    public func clearAll() {
        KeychainService.delete(forKey: KeychainService.anthropicAPIKey)
        KeychainService.delete(forKey: KeychainService.googleMapsAPIKey)
        anthropicKey = ""
        googleMapsKey = ""
    }
}
