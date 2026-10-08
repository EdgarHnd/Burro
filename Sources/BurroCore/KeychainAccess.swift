// Serialize permission policy around macOS's legacy Keychain as well as LAContext reads.
import Foundation
import Security

enum KeychainAccess {
    private static let lock = NSLock()

    // Claude uses the file-based login Keychain. LAContext alone only protects the
    // modern authentication path; the legacy API has a process-wide UI switch.
    // All Burro Keychain reads must pass through this synchronous, serialized scope.
    static func perform<T>(allowPrompt: Bool, operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try withInteraction(allowPrompt: allowPrompt, get: {
            var allowed: DarwinBoolean = false
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }, set: { SecKeychainSetUserInteractionAllowed($0) }, operation: operation)
    }

    static func defaultKeychainUnlocked() -> Bool? {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return nil }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return nil }
        return status & kSecUnlockStateStatus != 0
    }
    static func readIssue(status: OSStatus, unlocked: Bool?) -> UsageIssue {
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return unlocked == false ? .keychainLocked : .permissionRequired
        case errSecUserCanceled: return .permissionRequired
        case errSecItemNotFound: return .signInRequired
        default: return .unavailable
        }
    }

    static func withInteraction<T>(allowPrompt: Bool,
                                   get: () -> (OSStatus, Bool),
                                   set: (Bool) -> OSStatus,
                                   operation: () throws -> T) throws -> T {
        let (status, previous) = get()
        guard status == errSecSuccess else { throw UsageIssue.permissionRequired }
        guard set(allowPrompt) == errSecSuccess else { throw UsageIssue.permissionRequired }
        defer { _ = set(previous) }
        return try operation()
    }
}
