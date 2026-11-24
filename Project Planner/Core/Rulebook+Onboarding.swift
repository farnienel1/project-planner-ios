//
//  Rulebook+Onboarding.swift
//  Project Planner
//
//  RULEBOOK 1.85.0 §32 (owner 24 Nov): the "Getting started" checklist for new companies — the card at the top of Home
//  for admins. Every item, whether it is done, the progress words and when the card shows are the script's
//  (`onboardingChecklist`, `onboardingCardVisible`, `onboardingDismissWriteFields`); this file only passes inputs.
//

import Foundation

nonisolated struct RulebookOnboardingItem: Hashable, Sendable, Identifiable {
    let key: String
    let title: String
    let detail: String
    let done: Bool
    let optional: Bool
    /// `companyDetails`, `workingHours`, `paymentRuns`, `manageUsers`, `projects`, `insuranceAccreditations`.
    let destination: String
    var id: String { key }
}

nonisolated struct RulebookOnboardingChecklist: Hashable, Sendable {
    let items: [RulebookOnboardingItem]
    let doneCount: Int
    let total: Int
    let progressLabel: String
    let progress: Double
    let complete: Bool
    let ready: Bool
    let title: String
    let subtitle: String
}

/// The organisation fields `onboardingChecklist` reads, kept as stored (JSON text on `Organization.onboardingDocumentJSON`).
nonisolated enum OnboardingOrganizationDocument {
    static let storedKeys = ["name", "officeAddressLine1", "officePostcode", "officeAddress", "companyLogoURL", "payrollTimePolicy", "onboardingDismissedAt"]

    /// JSON text of those fields and `invoicing.{paymentRunMode, payePayday, payePaydayHistory}`; nil when none is stored.
    static func json(fromOrganizationData data: [String: Any]) -> String? {
        var out: [String: Any] = [:]
        for key in storedKeys {
            if let value = data[key], !(value is NSNull) { out[key] = FirebaseBackend.firestoreJSON(value) }
        }
        if let invoicing = data["invoicing"] as? [String: Any] {
            var inv: [String: Any] = [:]
            for key in ["paymentRunMode", "payePayday", "payePaydayHistory"] {
                if let value = invoicing[key] { inv[key] = FirebaseBackend.firestoreJSON(value) }
            }
            if !inv.isEmpty { out["invoicing"] = inv }
        }
        guard !out.isEmpty, JSONSerialization.isValidJSONObject(out),
              let bytes = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func document(json: String?) -> [String: Any] {
        guard let json, let bytes = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return [:] }
        return object
    }
}

extension CanonicalBusinessEngine {
    /// `onboardingChecklist(org, counts)`. A count still loading is nil (the checklist is then not `ready`).
    nonisolated static func onboardingChecklist(
        organization: [String: Any],
        people: Int?,
        pendingInvites: Int?,
        jobs: Int?,
        complianceDocuments: Int?
    ) -> RulebookOnboardingChecklist? {
        let counts: [String: Any] = [
            "people": people.map { $0 as Any } ?? NSNull(),
            "pendingInvites": pendingInvites.map { $0 as Any } ?? NSNull(),
            "jobs": jobs.map { $0 as Any } ?? NSNull(),
            "complianceDocuments": complianceDocuments.map { $0 as Any } ?? NSNull(),
        ]
        guard let row = callJSON("onboardingChecklist", arguments: [peopleDocumentJSON(organization), counts]) as? [String: Any],
              let rawItems = row["items"] as? [[String: Any]] else { return nil }
        let items = rawItems.compactMap { item -> RulebookOnboardingItem? in
            guard let key = item["key"] as? String, let title = item["title"] as? String else { return nil }
            return RulebookOnboardingItem(
                key: key,
                title: title,
                detail: item["detail"] as? String ?? "",
                done: item["done"] as? Bool ?? false,
                optional: item["optional"] as? Bool ?? false,
                destination: item["destination"] as? String ?? ""
            )
        }
        return RulebookOnboardingChecklist(
            items: items,
            doneCount: (row["doneCount"] as? NSNumber)?.intValue ?? 0,
            total: (row["total"] as? NSNumber)?.intValue ?? items.count,
            progressLabel: row["progressLabel"] as? String ?? "",
            progress: (row["progress"] as? NSNumber)?.doubleValue ?? 0,
            complete: row["complete"] as? Bool ?? false,
            ready: row["ready"] as? Bool ?? false,
            title: row["title"] as? String ?? "Getting started",
            subtitle: row["subtitle"] as? String ?? ""
        )
    }

    /// `onboardingCardVisible({ checklist, viewerIsAdmin, org })`: admins, counts loaded, a required item open, not hidden.
    nonisolated static func onboardingCardVisible(organization: [String: Any], people: Int?, pendingInvites: Int?, jobs: Int?, complianceDocuments: Int?, viewerIsAdmin: Bool) -> RulebookOnboardingChecklist? {
        let org = peopleDocumentJSON(organization)
        let counts: [String: Any] = [
            "people": people.map { $0 as Any } ?? NSNull(),
            "pendingInvites": pendingInvites.map { $0 as Any } ?? NSNull(),
            "jobs": jobs.map { $0 as Any } ?? NSNull(),
            "complianceDocuments": complianceDocuments.map { $0 as Any } ?? NSNull(),
        ]
        guard let checklist = callJSON("onboardingChecklist", arguments: [org, counts]) as? [String: Any],
              callJSON("onboardingCardVisible", arguments: [["checklist": checklist, "viewerIsAdmin": viewerIsAdmin, "org": org]]) as? Bool == true
        else { return nil }
        return onboardingChecklist(organization: organization, people: people, pendingInvites: pendingInvites, jobs: jobs, complianceDocuments: complianceDocuments)
    }

    /// `onboardingDismissWriteFields(uid)` (who hid it); the caller adds `onboardingDismissedAt` as a server timestamp.
    nonisolated static func onboardingDismissWriteFields(userId: String) -> [String: Any]? {
        callJSON("onboardingDismissWriteFields", arguments: [userId]) as? [String: Any]
    }

    nonisolated static func onboardingText(_ name: String, fallback: String) -> String {
        constant(name, as: String.self) ?? fallback
    }
}
