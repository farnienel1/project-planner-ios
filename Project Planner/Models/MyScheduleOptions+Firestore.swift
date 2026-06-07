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
            showOffice: data["showOffice"] as? Bool ?? true,
            showWorkingFromHome: data["showWorkingFromHome"] as? Bool ?? true,
            showSiteSurvey: data["showSiteSurvey"] as? Bool ?? true,
            customItems: (data["customItems"] as? [String]) ?? [],
            customItemEnabled: (data["customItemEnabled"] as? [String: Bool]) ?? [:]
        )
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
