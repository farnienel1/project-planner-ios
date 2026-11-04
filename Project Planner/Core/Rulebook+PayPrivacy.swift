//
//  Rulebook+PayPrivacy.swift
//  Project Planner
//
//  Rulebook 1.13.0 §8 / §16 (owner decision Q1, steps B and C): pay moves to the private
//  `organizations/{orgId}/payProfiles/{subjectId}`. Typed wrappers for `PAY_PROFILE_FIELDS`, `payProfilePath`,
//  `payProfileWriteFieldsFromProfileWrite`, `parsePayProfileDocument`, `overlayPayProfile` and `canViewPersonPay`
//  (web `lib/canonical/payProfiles.ts`, `payAccess.ts`). Nothing is decided here: every save that changes pay writes
//  the same fields to the pay profile in the users write's batch (web `addPayProfileWrite`), and pay is read pay
//  profile first, users document second.
//

import Foundation
import FirebaseAuth
import FirebaseFirestore

extension CanonicalBusinessEngine {
    /// `PAY_PROFILE_FIELDS`: `payBasis`, `dayRate`, `hourlyRate`, `employmentType`, `employmentTypeTransitionFrom`,
    /// `employmentTypeEffectiveAt`. Nil when the script did not answer.
    nonisolated static var payProfileFields: [String]? {
        constant("PAY_PROFILE_FIELDS", as: [String].self)
    }

    /// `payProfilePath(organizationId, subjectId)`. Nil when either id is blank or the script did not answer.
    nonisolated static func payProfilePath(organizationId: String, subjectId: String) -> String? {
        guard !organizationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !subjectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return callJSON("payProfilePath", arguments: [organizationId, subjectId]) as? String
    }

    /// `payProfileWriteFieldsFromProfileWrite(subjectId, profileWrite)`: the pay fields of a users write (and
    /// `userId`), or nil when the write changes no pay field. `profileWrite` may hold SDK sentinels
    /// (`FieldValue.delete()`, timestamps): the script decides which keys are pay keys on a JSON copy, and the values
    /// written are the caller's own, so a deleted rate is deleted on the pay profile too.
    nonisolated static func payProfileWriteFields(subjectId: String, profileWrite: [String: Any]) -> [String: Any]? {
        var probe: [String: Any] = [:]
        for key in profileWrite.keys { probe[key] = NSNull() }
        guard let row = callJSON("payProfileWriteFieldsFromProfileWrite", arguments: [subjectId, probe]) as? [String: Any] else {
            return nil
        }
        var out: [String: Any] = [:]
        for key in row.keys {
            if key == "userId" {
                out[key] = row[key]
            } else if let value = profileWrite[key] {
                out[key] = value
            }
        }
        return out.count > 1 ? out : nil
    }

    /// `parsePayProfileDocument(docId, data)` then `overlayPayProfile(person, profile)`: the person's pay fields from
    /// the pay profile where it has them, else the users document's. `profile` nil (missing, or not readable by
    /// this viewer) leaves the person as stored. Nil when the script did not answer.
    nonisolated static func overlayPayProfile(person: [String: Any], profileId: String, profile: [String: Any]?) -> [String: Any]? {
        guard let profile else { return person }
        guard let parsed = callJSON("parsePayProfileDocument", arguments: [profileId, profile]) else { return nil }
        return callJSON("overlayPayProfile", arguments: [person, parsed]) as? [String: Any]
    }

    /// `canViewPersonPay(viewer, subject, roster)`: the person, their active line managers, admins and super admins,
    /// and managers with Operatives access for operatives. False when the script did not answer (pay stays hidden).
    nonisolated static func canViewPersonPay(viewer: [String: Any], subject: [String: Any], roster: [[String: Any]]) -> Bool {
        callJSON("canViewPersonPay", arguments: [viewer, subject, roster]) as? Bool ?? false
    }
}

extension AppUser {
    /// The person as `canViewPersonPay` reads them: ids, email, active flag, role and permission flags, line managers.
    var payAccessSubject: [String: Any] {
        var row = permissionSubject
        for (key, value) in RulebookPeople.person(self) { row[key] = value }
        row["organizationId"] = organizationId
        return row
    }
}

extension UserStore {
    /// RULEBOOK 1.13.0 §8 `canViewPersonPay`: whether the signed-in person may see `subject`'s pay, pay basis and
    /// employment type. The platform owner (`isPlatformOwnerEmail`) always may.
    func canViewPay(of subject: AppUser) -> Bool {
        guard let viewer = currentUser else { return false }
        var viewerRow = viewer.payAccessSubject
        viewerRow["isPlatformOwner"] = CanonicalBusinessEngine.isPlatformOwnerEmail(viewer.email)
        return CanonicalBusinessEngine.canViewPersonPay(
            viewer: viewerRow,
            subject: subject.payAccessSubject,
            roster: organizationUsers.map { $0.payAccessSubject }
        )
    }
}

extension FirebaseBackend {
    /// Adds the pay-profile half of a users write to `batch` (web `addPayProfileWrite`): a merge of the changed pay
    /// fields with write metadata. Returns false when the write changes no pay field or no organisation is open.
    @discardableResult
    func addPayProfileWrite(to batch: WriteBatch, subjectId: String, profileWrite: [String: Any]) -> Bool {
        guard let orgId = currentOrganization?.firestoreDocumentId,
              let path = CanonicalBusinessEngine.payProfilePath(organizationId: orgId, subjectId: subjectId),
              let fields = CanonicalBusinessEngine.payProfileWriteFields(subjectId: subjectId, profileWrite: profileWrite) else {
            return false
        }
        batch.setData(WriteMetadata.stamped(fields, userId: auth.currentUser?.uid), forDocument: db.document(path), merge: true)
        return true
    }

    /// `users/{userId}` partial update plus its pay profile in ONE batch (RULEBOOK 1.13.0 Q1 step B), so pay is never
    /// written to one document without the other.
    /// RULEBOOK 1.26.0 §8: the users half is `CanonicalBusinessEngine.sharedDocumentPayWrite(payload, { privatePay })`
    /// — unchanged while the switch is off, without any pay field while it is on (pay then goes only to the pay
    /// profile). A users half left with nothing but write metadata is not sent.
    func updateUserDocumentWithPayProfile(userId: String, payload: [String: Any]) async throws {
        let batch = db.batch()
        let shared = CanonicalBusinessEngine.sharedDocumentPayWrite(payload, privatePay: SecuritySwitchContext.privatePay)
        if Self.hasFieldsBesidesMetadata(shared) {
            batch.updateData(shared, forDocument: db.collection("users").document(userId))
        }
        addPayProfileWrite(to: batch, subjectId: userId, profileWrite: payload)
        try await batch.commit()
    }

    /// The pay-profile half of a write on its own (RULEBOOK 1.26.0, `privatePay` on: a new users document or invite
    /// placeholder whose shared copy carries no pay). Nothing when the write has no pay field.
    func writePayProfileOnly(subjectId: String, profileWrite: [String: Any]) async throws {
        let batch = db.batch()
        guard addPayProfileWrite(to: batch, subjectId: subjectId, profileWrite: profileWrite) else { return }
        try await batch.commit()
    }

    /// True when a write names a field other than `updatedAt` / `updatedBy` / `updatedFrom`.
    nonisolated static func hasFieldsBesidesMetadata(_ write: [String: Any]) -> Bool {
        !Set(write.keys).subtracting(["updatedAt", "updatedBy", "updatedFrom"]).isEmpty
    }

    /// The pay profile document as stored, or nil when it does not exist or this viewer may not read it (the rules
    /// decide, `canViewPayOf`).
    func loadPayProfile(subjectId: String) async -> [String: Any]? {
        guard let orgId = currentOrganization?.firestoreDocumentId,
              let path = CanonicalBusinessEngine.payProfilePath(organizationId: orgId, subjectId: subjectId) else { return nil }
        do {
            let snap = try await db.document(path).getDocument(source: .server)
            return snap.exists ? snap.data() : nil
        } catch {
            return nil
        }
    }
}

extension AppUser {
    /// The pay fields of this users row in the shape `overlayPayProfile` reads (`PAY_PROFILE_FIELDS`).
    var payProfileFieldsJSON: [String: Any] {
        [
            "payBasis": payBasis.map { $0 as Any } ?? NSNull(),
            "dayRate": dayRate.map { $0 as Any } ?? NSNull(),
            "hourlyRate": hourlyRate.map { $0 as Any } ?? NSNull(),
            "employmentType": employmentType.rawValue,
            "employmentTypeTransitionFrom": employmentTypeTransitionFrom.map { $0.rawValue as Any } ?? NSNull(),
            "employmentTypeEffectiveAt": employmentTypeEffectiveAt.map { $0.timeIntervalSince1970 * 1000 as Any } ?? NSNull(),
        ]
    }

    /// The pay a screen shows (RULEBOOK 1.26.0 §8, `CanonicalBusinessEngine` `overlayPayProfile` gated by `privatePay`):
    /// the pay profile laid over the users document while the switch is on; the users document as stored while it is
    /// off, whatever the pay profile says.
    func payShown(with profile: [String: Any]?, privatePay: Bool) -> AppUser {
        privatePay ? overlayingPayProfile(profile) : self
    }

    /// `self` with its pay read pay profile first (`overlayPayProfile`), the users document second. `profile` is the
    /// `payProfiles/{id}` document as stored (nil: none, or not readable by this viewer).
    func overlayingPayProfile(_ profile: [String: Any]?) -> AppUser {
        guard let profile,
              let row = CanonicalBusinessEngine.overlayPayProfile(
                  person: payProfileFieldsJSON,
                  profileId: id,
                  profile: FirebaseBackend.firestoreJSON(profile) as? [String: Any]
              ) else { return self }
        func number(_ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
        func text(_ key: String) -> String? {
            let value = (row[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
        var out = self
        out.payBasis = text("payBasis")
        out.dayRate = number("dayRate")
        out.hourlyRate = number("hourlyRate")
        out.employmentType = EmploymentType.fromCanonical(text("employmentType") ?? employmentType.rawValue)
        out.employmentTypeTransitionFrom = text("employmentTypeTransitionFrom").map { EmploymentType.fromCanonical($0) }
        switch row["employmentTypeEffectiveAt"] {
        case let stamp as [String: Any]:
            if let seconds = (stamp["seconds"] as? NSNumber)?.doubleValue {
                out.employmentTypeEffectiveAt = Date(timeIntervalSince1970: seconds)
            }
        case let ms as NSNumber:
            out.employmentTypeEffectiveAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        default:
            out.employmentTypeEffectiveAt = nil
        }
        return out
    }
}

extension UserStore {
    /// RULEBOOK 1.13.0 §8 (Q1 step C): reads `payProfiles/{subjectId}` when the signed-in person may see this
    /// person's pay (`canViewPersonPay`) and lays it over the loaded row (`overlayPayProfile`). Returns the row as
    /// shown; the roster copy is updated so other screens show the same pay.
    ///
    /// RULEBOOK 1.26.0 §8: only while `privatePay` is on for the organisation (`AppUser.payShown`). While it is off pay
    /// is read from the users document as stored: an older build writes pay only there, so a pay profile may be stale,
    /// and seeding the editor from it would show (and save back) an old rate.
    @discardableResult
    func refreshPayFromPayProfile(of subject: AppUser) async -> AppUser {
        guard SecuritySwitchContext.privatePay, canViewPay(of: subject), let firebaseBackend else { return subject }
        guard let profile = await firebaseBackend.loadPayProfile(subjectId: subject.id) else { return subject }
        let overlaid = subject.payShown(with: profile, privatePay: SecuritySwitchContext.privatePay)
        if overlaid != subject, let index = organizationUsers.firstIndex(where: { $0.id == subject.id }) {
            organizationUsers[index] = overlaid
        }
        return overlaid
    }
}
