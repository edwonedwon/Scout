import Foundation
import Security

/// Stores and retrieves sensitive values.
/// DEBUG builds use UserDefaults to avoid macOS Keychain prompts on every rebuild.
/// Release builds use the system Keychain.
public enum KeychainService {
    private static let service = "com.scout.app"

    public static func save(_ value: String, forKey key: String) throws {
        #if DEBUG
        UserDefaults.standard.set(value, forKey: debugKey(key))
        #else
        try saveToKeychain(value, forKey: key)
        #endif
    }

    public static func load(forKey key: String) -> String? {
        #if DEBUG
        return UserDefaults.standard.string(forKey: debugKey(key))
        #else
        return loadFromKeychain(forKey: key)
        #endif
    }

    public static func delete(forKey key: String) {
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugKey(key))
        #else
        deleteFromKeychain(forKey: key)
        #endif
    }

    private static func debugKey(_ key: String) -> String { "debug.\(service).\(key)" }

    // MARK: - Keychain (release only)

    private static func saveToKeychain(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    private static func loadFromKeychain(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteFromKeychain(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public enum KeychainError: LocalizedError {
        case saveFailed(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .saveFailed(let status): return "Keychain save failed: \(status)"
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
