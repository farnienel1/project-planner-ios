//
//  MyScheduleOptions+Firestore.swift
//  Project Planner
//
//  Shared org-level My Schedule options (`organizations/{orgId}.settings.myScheduleOptions`).
//

import Foundation

extension MyScheduleOptions {
    static func fromFirestore(_ data: [String: Any]) -> MyScheduleOptions {
        MyScheduleOptions(
            showOffice: Self.shown(data["showOffice"]),
            showWorkingFromHome: Self.shown(data["showWorkingFromHome"]),
            showSiteSurvey: Self.shown(data["showSiteSurvey"]),
            customItems: (data["customItems"] as? [String]) ?? [],
            customItemEnabled: Self.enabledFlags(data["customItemEnabled"])
        )
    }

    /// Missing means shown. An explicit false stays off.
    private static func shown(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    private static func enabledFlags(_ value: Any?) -> [String: Bool] {
        if let flags = value as? [String: Bool] { return flags }
        guard let raw = value as? [String: Any] else { return [:] }
        return raw.reduce(into: [:]) { out, pair in
            if let flag = pair.value as? Bool {
                out[pair.key] = flag
            } else if let number = pair.value as? NSNumber {
                out[pair.key] = number.boolValue
            }
        }
    }

    func asFirestoreDictionary() -> [String: Any] {
        [
            "showOffice": showOffice,
            "showWorkingFromHome": showWorkingFromHome,
            "showSiteSurvey": showSiteSurvey,
            "customItems": customItems,
            "customItemEnabled": Dictionary(uniqueKeysWithValues: customItems.map { ($0, customItemEnabled[$0] ?? true) }),
        ]
    }
}
