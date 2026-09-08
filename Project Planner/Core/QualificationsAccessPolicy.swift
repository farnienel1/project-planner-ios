//
//  QualificationsAccessPolicy.swift
//  Project Planner
//
//  Rules for organisation vs personal qualifications access.
//

import Foundation

/// Access rules for the Qualifications hub.
///
/// Organisation qualification templates are **organisation-owned** Firestore data
/// (`organizations/{orgId}/qualifications`). Personal assignments live on each
/// operative profile. Changing who may *manage* the catalogue must never rewrite
/// or delete either store.
enum QualificationsAccessPolicy {
    /// Whether the user may add / rename / delete organisation qualification templates.
    static func canManageOrganisationCatalogue(user: AppUser?, isOperativeMode: Bool, hasAdminAccess: Bool) -> Bool {
        if isOperativeMode { return false }
        if hasAdminAccess { return true }
        guard let user else { return false }
        return user.permissions.qualifications
    }

    /// Whether the user may open the Qualifications hub at all (at least My Qualifications).
    static func canOpenQualificationsHub(user: AppUser?, isOperativeMode: Bool, hasAdminAccess: Bool) -> Bool {
        if isOperativeMode { return false }
        if hasAdminAccess { return true }
        guard let user else { return false }
        return user.permissions.manager || user.permissions.qualifications
    }

    /// Turning manage-org off is a UI permission change only — catalogues and personal
    /// assignments must remain intact. Call sites that update `permissions.qualifications`
    /// must not invoke `OperativeStore.deleteQualification` / clear `Operative.qualifications`.
    static let managePermissionDoesNotMutateStoredQualifications = true
}
