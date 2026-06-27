import Foundation

/// Stores and retrieves API keys.
///
/// Uses `UserDefaults` (app settings) on ALL builds. We intentionally do NOT use the macOS
/// Keychain: a sandboxed, re-signed app accessing a Keychain item created under a different
/// signature/bundle triggers a "wants to use confidential information" password prompt on every
/// launch (and the `keychain-access-groups` entitlement that would quiet it is rejected by the
/// Mac App Store — error 90285). These are the user's own API keys in their own app; UserDefaults
/// is the right trade-off for this app and produces no prompt.
public enum KeychainService {
    private static let service = "com.scout.app"

    public static func save(_ value: String, forKey key: String) throws {
        UserDefaults.standard.set(value, forKey: storageKey(key))
    }

    public static func load(forKey key: String) -> String? {
        UserDefaults.standard.string(forKey: storageKey(key))
    }

    public static func delete(forKey key: String) {
        UserDefaults.standard.removeObject(forKey: storageKey(key))
    }

    private static func storageKey(_ key: String) -> String { "\(service).\(key)" }

    public enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Key save failed: \(status)"
            }
        }
    }

    // MARK: - Well-known keys
    public static let anthropicAPIKey = "anthropic_api_key"
    public static let anthropicAdminKey = "anthropic_admin_key"
    public static let googleMapsAPIKey = "google_maps_api_key"
    public static let flickrAPIKey = "flickr_api_key"
    public static let foursquareAPIKey = "foursquare_api_key"
}
