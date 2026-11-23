import Foundation
import Security

/// Where the last-written token is kept. Production uses the Keychain (it survives an app delete and reinstall, which
/// is the usual reason a phone gets a new FCM token); tests use memory.
protocol PushTokenMemoryStore {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

/// RULEBOOK §13: this device's push token belongs to one account and the device writes it (a device-owned field).
/// When Firebase gives the phone a NEW token (refresh, reinstall), the token it wrote before is still on the users
/// document and FCM may keep accepting it, so the phone got every push twice (owner report 23 Nov: 8 tokens on one
/// line manager). The device remembers, per signed-in account, the last token it wrote, and replaces it on the next
/// write. Device-only state, never synced.
final class PushTokenDeviceMemory {
    static let shared = PushTokenDeviceMemory(store: KeychainPushTokenStore())

    private let store: PushTokenMemoryStore

    init(store: PushTokenMemoryStore) {
        self.store = store
    }

    private static func key(uid: String) -> String {
        "pushTokenLastWritten." + uid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lastWrittenToken(uid: String) -> String? {
        let trimmedUid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUid.isEmpty else { return nil }
        let value = store.string(forKey: Self.key(uid: trimmedUid))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    func recordWritten(token: String, uid: String) {
        let trimmedUid = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUid.isEmpty, !trimmedToken.isEmpty else { return }
        store.set(trimmedToken, forKey: Self.key(uid: trimmedUid))
    }

    /// The tokens a write of `current` takes off the account: this device's previous token, when it is a different one.
    static func tokensReplacedBy(current: String, previous: String?) -> Set<String> {
        let now = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = (previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !now.isEmpty, !before.isEmpty, before != now else { return [] }
        return [before]
    }

    /// Sign-out removes this device's current token and the one it last wrote for the account (when they differ).
    static func tokensToRemoveOnSignOut(current: String, previous: String?) -> [String] {
        var out: [String] = []
        for raw in [current, previous ?? ""] {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty, !out.contains(token) { out.append(token) }
        }
        return out
    }
}

/// Generic-password Keychain items, this device only (never restored onto another phone from a backup, where the
/// remembered token would not be that phone's).
final class KeychainPushTokenStore: PushTokenMemoryStore {
    private let service = "com.projectplanner.pushTokenLastWritten"

    private func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func string(forKey key: String) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return UserDefaults.standard.string(forKey: key)
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add.merge(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        // A Keychain that refuses (rare) falls back to UserDefaults: still survives a relaunch, not a reinstall.
        if status != errSecSuccess {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}
