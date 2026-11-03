//
//  OrganizationBillingMap.swift
//  Project Planner
//
//  Decodes organizations/{orgId}.billing into a JSON object the packed hasAccess export can read.
//  Field names stay as they are in Firestore. This file does not decide access.
//

import Foundation
import FirebaseFirestore

nonisolated enum OrganizationBillingMap {
    /// Nested `billing` map, or nil when that field is absent. Top-level trial flags are ignored.
    static func payload(from organizationData: [String: Any]) -> [String: Any]? {
        guard let raw = organizationData["billing"] else { return nil }
        if let map = raw as? [String: Any] {
            return jsonSafeMap(map)
        }
        guard let map = raw as? NSDictionary else { return nil }
        var swift: [String: Any] = [:]
        for (key, value) in map {
            guard let name = key as? String else { continue }
            swift[name] = value
        }
        return jsonSafeMap(swift)
    }

    /// Stable JSON for the nested map. Nil when `billing` is absent or cannot be encoded.
    static func storedJSON(from organizationData: [String: Any]) -> String? {
        guard let payload = payload(from: organizationData) else { return nil }
        return jsonText(payload)
    }

    static func dictionary(json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func jsonText(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonSafeMap(_ map: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in map {
            if let safe = jsonSafe(value) {
                out[key] = safe
            }
        }
        return out
    }

    /// Firestore timestamps become `{ seconds }`, which the packed `timestampMs` already accepts.
    private static func jsonSafe(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let text = value as? String { return text }
        if let flag = value as? Bool { return flag }
        if let timestamp = value as? Timestamp {
            return ["seconds": NSNumber(value: timestamp.seconds)]
        }
        if let date = value as? Date {
            return ["seconds": NSNumber(value: Int64(date.timeIntervalSince1970.rounded()))]
        }
        if let number = value as? NSNumber { return number }
        if let map = value as? [String: Any] { return jsonSafeMap(map) }
        if let list = value as? [Any] { return list.compactMap { jsonSafe($0) } }
        return nil
    }
}

/// Words shown when `CanonicalBusinessEngine.hasAccess` is false. Same words for every role. App Store 3.1.1 /
/// 3.1.3: no price, no renewal, no link to buy or renew outside the app.
enum SubscriptionLapsedCopy {
    /// Short label on the organisation switcher row.
    static let phrase = "subscription is not active"
    /// RULEBOOK 1.13.0 §19 `SUBSCRIPTION_LAPSED_MESSAGE`, shown to everyone.
    static var headline: String { CanonicalBusinessEngine.subscriptionLapsedMessage }

    /// `SUBSCRIPTION_LAPSED_ADMIN_NOTE` for admins, nothing for anyone else. Never a link or a price.
    static func detail(isAdmin: Bool) -> String? {
        isAdmin ? CanonicalBusinessEngine.subscriptionLapsedAdminNote : nil
    }

    static func visibleText(isAdmin: Bool) -> String {
        [headline, detail(isAdmin: isAdmin)].compactMap { $0 }.joined(separator: "\n")
    }
}
