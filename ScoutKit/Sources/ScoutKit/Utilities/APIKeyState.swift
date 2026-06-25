import Foundation
import Combine

/// Observable state for the user's API keys. Bind this to your Settings view.
@MainActor
public final class APIKeyState: ObservableObject {
    public static let shared = APIKeyState()

    @Published public var anthropicKey: String = ""
    @Published public var anthropicAdminKey: String = ""
    @Published public var googleMapsKey: String = ""
    @Published public var flickrKey: String = ""
    @Published public var foursquareKey: String = ""

    public var anthropicKeyIsSet: Bool { !anthropicKey.isEmpty }
    public var anthropicAdminKeyIsSet: Bool { !anthropicAdminKey.isEmpty }
    public var googleMapsKeyIsSet: Bool { !googleMapsKey.isEmpty }
    public var flickrKeyIsSet: Bool { !flickrKey.isEmpty }
    public var foursquareKeyIsSet: Bool { !foursquareKey.isEmpty }

    private init() {
        anthropicKey = KeychainService.load(forKey: KeychainService.anthropicAPIKey) ?? ""
        anthropicAdminKey = KeychainService.load(forKey: KeychainService.anthropicAdminKey) ?? ""
        googleMapsKey = KeychainService.load(forKey: KeychainService.googleMapsAPIKey) ?? ""
        flickrKey = KeychainService.load(forKey: KeychainService.flickrAPIKey) ?? ""
        foursquareKey = KeychainService.load(forKey: KeychainService.foursquareAPIKey) ?? ""
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

    public func saveAnthropicAdminKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            KeychainService.delete(forKey: KeychainService.anthropicAdminKey)
            anthropicAdminKey = ""
        } else {
            try KeychainService.save(trimmed, forKey: KeychainService.anthropicAdminKey)
            anthropicAdminKey = trimmed
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

    public func saveFlickrKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            KeychainService.delete(forKey: KeychainService.flickrAPIKey)
            flickrKey = ""
        } else {
            try KeychainService.save(trimmed, forKey: KeychainService.flickrAPIKey)
            flickrKey = trimmed
        }
    }

    public func saveFoursquareKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            KeychainService.delete(forKey: KeychainService.foursquareAPIKey)
            foursquareKey = ""
        } else {
            try KeychainService.save(trimmed, forKey: KeychainService.foursquareAPIKey)
            foursquareKey = trimmed
        }
    }

    public func clearAll() {
        KeychainService.delete(forKey: KeychainService.anthropicAPIKey)
        KeychainService.delete(forKey: KeychainService.anthropicAdminKey)
        KeychainService.delete(forKey: KeychainService.googleMapsAPIKey)
        KeychainService.delete(forKey: KeychainService.flickrAPIKey)
        KeychainService.delete(forKey: KeychainService.foursquareAPIKey)
        anthropicKey = ""
        anthropicAdminKey = ""
        googleMapsKey = ""
        flickrKey = ""
        foursquareKey = ""
    }
}
