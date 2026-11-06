//
//  Rulebook+MaterialOrderAccess.swift
//  Project Planner
//
//  Rulebook 1.15.0 (docs/RULEBOOK.md §16): who sends material quotes and orders (`canSendMaterialOrders`: admins and
//  super admins outside operative mode, and managers; never an operative) and to whom (`materialOrderRecipientCheck`:
//  saved wholesaler contacts, the sender's own copy, at most `MATERIAL_ORDER_TYPED_RECIPIENTS_MAX` typed addresses).
//  Answers come from the packed script; nothing is decided here.
//

import Foundation

/// `materialOrderRecipientCheck` result.
nonisolated struct MaterialOrderRecipientCheckResult: Equatable, Sendable {
    let ok: Bool
    /// `invalid`, `none` or `too_many_typed` when refused.
    let reason: String?
    let message: String?
    let saved: [String]
    let typed: [String]
}

extension CanonicalBusinessEngine {
    /// `canSendMaterialOrders(viewer)` for a staff role. False when the script did not answer.
    nonisolated static func canSendMaterialOrders(_ role: CanonicalStaffAccountRole) -> Bool {
        let viewer: [String: Any] = [
            "isSuperAdmin": role.isSuperAdmin,
            "isAdmin": role.isAdmin,
            "isManager": role.isManager,
            "isOperativeMode": role.isOperativeMode,
        ]
        return callJSON("canSendMaterialOrders", arguments: [viewer]) as? Bool ?? false
    }

    /// RULEBOOK 1.33.0 §16 `canManageMaterialCatalogue(viewer)`: who adds, edits and deletes Materials catalogue items
    /// and prices — admins and super admins outside operative mode only. False when the script did not answer.
    nonisolated static func canManageMaterialCatalogue(_ role: CanonicalStaffAccountRole) -> Bool {
        let viewer: [String: Any] = [
            "isSuperAdmin": role.isSuperAdmin,
            "isAdmin": role.isAdmin,
            "isManager": role.isManager,
            "isOperativeMode": role.isOperativeMode,
        ]
        return callJSON("canManageMaterialCatalogue", arguments: [viewer]) as? Bool ?? false
    }

    /// `MATERIAL_ORDER_TYPED_RECIPIENTS_MAX` (3).
    nonisolated static var materialOrderTypedRecipientsMax: Int {
        constant("MATERIAL_ORDER_TYPED_RECIPIENTS_MAX", as: Int.self) ?? 3
    }

    /// `MATERIAL_ORDER_TYPED_RECIPIENTS_MESSAGE`.
    nonisolated static var materialOrderTypedRecipientsMessage: String {
        constant("MATERIAL_ORDER_TYPED_RECIPIENTS_MESSAGE", as: String.self)
            ?? "Add at most 3 email addresses that are not saved on a wholesaler. Save a regular supplier as a wholesaler contact."
    }

    /// `materialOrderRecipientCheck({ recipients, savedContactEmails, senderEmail })`. Nil when the script did not answer.
    nonisolated static func materialOrderRecipientCheck(
        recipients: [String],
        savedContactEmails: [String],
        senderEmail: String?
    ) -> MaterialOrderRecipientCheckResult? {
        var input: [String: Any] = ["recipients": recipients, "savedContactEmails": savedContactEmails]
        if let senderEmail, !senderEmail.isEmpty { input["senderEmail"] = senderEmail }
        guard let row = callJSON("materialOrderRecipientCheck", arguments: [input]) as? [String: Any],
              let ok = row["ok"] as? Bool else { return nil }
        return MaterialOrderRecipientCheckResult(
            ok: ok,
            reason: row["reason"] as? String,
            message: row["message"] as? String,
            saved: (row["saved"] as? [Any])?.compactMap { $0 as? String } ?? [],
            typed: (row["typed"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }
}
