//
//  LocalLayoutPreferences.swift
//  Project Planner
//
//  Home quick-action order and bottom-bar tab order live in UserDefaults on device.
//  They survive relaunch and sign-in. Uninstalling the app (or wiping the device)
//  is what clears them — that is expected iOS behaviour.
//

import Foundation
import FirebaseAuth

enum LocalLayoutPreferences {
    private static let anonymousFallback = "anonymous"

    static var signedInUserId: String? {
        Auth.auth().currentUser?.uid
    }

    static func quickActionOrderKey(userId: String) -> String {
        "homeQuickActionOrder.\(userId)"
    }

    static func tabOrderKey(userId: String) -> String {
        "bottomBarMovableTabOrder.\(userId)"
    }

    /// Copy any layout saved under `anonymous` onto the signed-in key the first time that key is empty.
    static func migrateAnonymousLayoutsIfNeeded(userId: String) {
        guard userId != anonymousFallback else { return }
        let defaults = UserDefaults.standard

        let quickKey = quickActionOrderKey(userId: userId)
        let anonQuickKey = quickActionOrderKey(userId: anonymousFallback)
        let existingQuick = defaults.array(forKey: quickKey) as? [String]
        if existingQuick == nil || existingQuick?.isEmpty == true,
           let anonQuick = defaults.array(forKey: anonQuickKey) as? [String],
           !anonQuick.isEmpty {
            defaults.set(anonQuick, forKey: quickKey)
        }

        let tabKey = tabOrderKey(userId: userId)
        let anonTabKey = tabOrderKey(userId: anonymousFallback)
        let existingTab = defaults.string(forKey: tabKey) ?? ""
        if existingTab.isEmpty,
           let anonTab = defaults.string(forKey: anonTabKey),
           !anonTab.isEmpty {
            defaults.set(anonTab, forKey: tabKey)
        }
    }

    static func loadQuickActionOrder(userId: String) -> [String]? {
        migrateAnonymousLayoutsIfNeeded(userId: userId)
        guard let saved = UserDefaults.standard.array(forKey: quickActionOrderKey(userId: userId)) as? [String] else {
            return nil
        }
        var seen = Set<String>()
        let filtered = saved.filter { !$0.isEmpty && seen.insert($0).inserted }
        return filtered.isEmpty ? nil : filtered
    }

    static func saveQuickActionOrder(_ ids: [String], userId: String) {
        guard userId != anonymousFallback else { return }
        UserDefaults.standard.set(ids, forKey: quickActionOrderKey(userId: userId))
    }

    static func loadTabOrder(userId: String) -> [Int] {
        migrateAnonymousLayoutsIfNeeded(userId: userId)
        let raw = UserDefaults.standard.string(forKey: tabOrderKey(userId: userId)) ?? ""
        return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func saveTabOrder(_ tags: [Int], userId: String) {
        guard userId != anonymousFallback, !tags.isEmpty else { return }
        let raw = tags.map(String.init).joined(separator: ",")
        UserDefaults.standard.set(raw, forKey: tabOrderKey(userId: userId))
    }
}
