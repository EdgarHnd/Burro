// Burro's own Keychain items (generic passwords in the login keychain). Today this holds the
// Convex URL and owner token you import for shared to-dos; nothing is written to disk in plain text.
import Foundation
import Security
import BurroCore

enum Keychain {
    static let service = "local.burro.worktrees.convex"

    static func read(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    @discardableResult static func write(_ data: Data, account: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Burro — Convex sync"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The imported Convex deployment for to-dos, kept in the Keychain.
enum ConvexCredentials {
    private static let account = "todos"
    private struct Stored: Codable { let url: String; let token: String }
    static func load() -> ConvexConfig? {
        guard let data = Keychain.read(account: account), let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let url = ConvexConfig.validURL(stored.url) else { return nil }
        return ConvexConfig(url: url, token: stored.token)
    }
    @discardableResult static func save(_ config: ConvexConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(Stored(url: config.url.absoluteString, token: config.token)) else { return false }
        return Keychain.write(data, account: account)
    }
    static func clear() { Keychain.delete(account: account) }
    /// Maurice's gitignored secrets file, where its iPhone build reads the same values.
    static let mauriceSecrets = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Dev/maurice-app/Config/Secrets.xcconfig")
}
