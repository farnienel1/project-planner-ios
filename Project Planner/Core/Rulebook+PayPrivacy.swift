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

    /// `canViewPersonPay(viewer, subject, roster, { context })`: the person, admins and super admins, managers with
    /// Operatives access for operatives, and the platform owner. RULEBOOK 1.32.0 §8 (owner decisions 5 Nov): a line
    /// manager who is none of those sees a report's pay only with `context` `.timesheetReview` (the timesheets they
    /// review); `.profile` (people profile, Manage Users, rate history) never. False when the script did not answer
    /// (pay stays hidden).
    nonisolated static func canViewPersonPay(
        viewer: [String: Any],
        subject: [String: Any],
        roster: [[String: Any]],
        context: RulebookPayViewContext
    ) -> Bool {
        callJSON("canViewPersonPay", arguments: [viewer, subject, roster, ["context": context.rawValue]]) as? Bool ?? false
    }

    // MARK: Weekly report pay summary (1.32.0 §7, §8)

    /// `PAY_HIDDEN_CELL_LABEL`: the rate and pay cells of a person whose pay the viewer may not see. Nil when the script
    /// did not answer.
    nonisolated static var payHiddenCellLabel: String? {
        constant("PAY_HIDDEN_CELL_LABEL", as: String.self)
    }

    /// `PAY_HIDDEN_NOTE`: the note under the pay summary when some people's pay is hidden. Nil when the script did not
    /// answer.
    nonisolated static var payHiddenNote: String? {
        constant("PAY_HIDDEN_NOTE", as: String.self)
    }

    /// `reportPayForViewer(rows, { viewer, roster })`: the weekly report pay summary for one viewer. Each row is
    /// `{ lines: [{ rate, pay, rateText?, payLabel?, isPaye }], personTotal, personTotalLabel?, paySubject? }` plus any
    /// keys the caller keeps (they come back unchanged, in the same order). A hidden row comes back with its rate and
    /// pay cells `PAY_HIDDEN_CELL_LABEL`; `grandTotal` covers the visible rows only. Nil when the script did not answer.
    nonisolated static func reportPayForViewer(
        rows: [[String: Any]],
        viewer: [String: Any]?,
        roster: [[String: Any]]
    ) -> RulebookReportPayForViewer? {
        let input: [String: Any] = ["viewer": RulebookJSON.orNull(viewer), "roster": roster]
        guard let answer = callJSON("reportPayForViewer", arguments: [rows, input]) as? [String: Any],
              let out = answer["rows"] as? [[String: Any]] else { return nil }
        return RulebookReportPayForViewer(
            rows: out,
            grandTotal: (answer["grandTotal"] as? NSNumber)?.doubleValue ?? 0,
            hiddenPeople: (answer["hiddenPeople"] as? NSNumber)?.intValue ?? 0
        )
    }

    // MARK: Weekly report access (1.32.0 §7, §11)

    /// `canOpenWeeklyReport(user)` (owner decision 5 Nov): admins and super admins only, read from the level (a
    /// manager's stored `weeklyReports` is ignored); an inactive person never. Every way in asks this. False when the
    /// script did not answer.
    nonisolated static func canOpenWeeklyReport(_ user: [String: Any]) -> Bool {
        callJSON("canOpenWeeklyReport", arguments: [user]) as? Bool ?? false
    }
}

/// RULEBOOK 1.32.0 §8 `PayViewContext`: where pay is shown. `profile` is the people profile, Manage Users and rate
/// history; `timesheetReview` is only the timesheets a line manager reviews.
nonisolated enum RulebookPayViewContext: String, Sendable {
    case profile
    case timesheetReview
}

/// `reportPayForViewer` result: the rows (as sent, hidden ones with `PAY_HIDDEN_CELL_LABEL` cells), the grand total over
/// the visible rows, and how many people were hidden (show `PAY_HIDDEN_NOTE` when above zero).
nonisolated struct RulebookReportPayForViewer: @unchecked Sendable {
    let rows: [[String: Any]]
    let grandTotal: Double
    let hiddenPeople: Int
}

extension AppUser {
    /// RULEBOOK 1.32.0 §7, §11 `CanonicalBusinessEngine.canOpenWeeklyReport`: this person may open the Weekly report
    /// (their stored permission fields with `isActive`).
    var canOpenWeeklyReport: Bool {
        var row = permissionSubject
        row["isActive"] = isActive
        return CanonicalBusinessEngine.canOpenWeeklyReport(row)
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
    /// employment type. The platform owner (`isPlatformOwnerEmail`) always may. RULEBOOK 1.32.0: `context` says where
    /// the pay is shown — `.profile` for Manage Users and profiles (a plain line manager never), `.timesheetReview` only
    /// on the timesheets a line manager reviews.
    func canViewPay(of subject: AppUser, context: RulebookPayViewContext) -> Bool {
        guard let viewerRow = payViewerRow else { return false }
        return CanonicalBusinessEngine.canViewPersonPay(
            viewer: viewerRow,
            subject: subject.payAccessSubject,
            roster: organizationUsers.map { $0.payAccessSubject },
            context: context
        )
    }

    /// The signed-in person as `canViewPersonPay` / `reportPayForViewer` read a viewer (with the platform owner flag).
    var payViewerRow: [String: Any]? {
        guard let viewer = currentUser else { return nil }
        var viewerRow = viewer.payAccessSubject
        viewerRow["isPlatformOwner"] = CanonicalBusinessEngine.isPlatformOwnerEmail(viewer.email)
        return viewerRow
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

}

extension AppUser {
    /// RULEBOOK 1.26.1 §8 `CanonicalBusinessEngine.payEditorStartingValues(person, profile, { privatePay })`: the pay a
    /// screen shows and an editor starts from — and saves against. `record` is the person with their pay profile laid
    /// over while `privatePay` is on; the users document exactly as stored while it is off (`source` `users`: `self`
    /// is returned unchanged). `profile` is the `payProfiles/{profileId}` document as stored (the person's own id, else
    /// a former invite id), or nil.
    func payShown(with profile: [String: Any]?, profileId: String? = nil, privatePay: Bool) -> AppUser {
        guard let answer = CanonicalBusinessEngine.payEditorStartingValues(
            person: payProfileFieldsJSON,
            profileId: profileId ?? id,
            profile: profile.flatMap { FirebaseBackend.firestoreJSON($0) as? [String: Any] },
            privatePay: privatePay
        ), answer.fromPayProfile else { return self }
        return applyingPayRecord(answer.record)
    }

    /// `self` with its pay read pay profile first (`overlayPayProfile`), the users document second. `profile` is the
    /// `payProfiles/{id}` document as stored (nil: none, or not readable by this viewer). Only `payShown` decides when.
    func overlayingPayProfile(_ profile: [String: Any]?) -> AppUser {
        guard let profile,
              let row = CanonicalBusinessEngine.overlayPayProfile(
                  person: payProfileFieldsJSON,
                  profileId: id,
                  profile: FirebaseBackend.firestoreJSON(profile) as? [String: Any]
              ) else { return self }
        return applyingPayRecord(row)
    }

    /// The `PAY_PROFILE_FIELDS` of a script record laid onto this person (a mapping, not a rule).
    func applyingPayRecord(_ row: [String: Any]) -> AppUser {
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

    /// This person with only the pay fields of `record` (the editor's starting record), every other field as held.
    func withPayFields(of record: AppUser) -> AppUser {
        var out = self
        out.payBasis = record.payBasis
        out.dayRate = record.dayRate
        out.hourlyRate = record.hourlyRate
        out.employmentType = record.employmentType
        out.employmentTypeTransitionFrom = record.employmentTypeTransitionFrom
        out.employmentTypeEffectiveAt = record.employmentTypeEffectiveAt
        return out
    }
}

/// RULEBOOK 1.26.1 §8: when a pay editor's starting record (`CanonicalBusinessEngine.payEditorStartingValues`) is
/// ready. A `securitySwitchesDidChange` while the editor is open starts a new read (`switchChanged`): Save waits again
/// while `privatePay` is on, and a read begun before the change is dropped (`finish` with an old generation).
/// State only — the record itself always comes from the rulebook.
struct PayEditorLoadGate: Equatable {
    private(set) var loaded = false
    private(set) var generation = 0

    /// True while `privatePay` is on and the current read has not finished: the form and Save wait.
    func isLoading(privatePay: Bool) -> Bool { privatePay && !loaded }

    /// The switches changed while the editor is open: read the record again.
    mutating func switchChanged() {
        loaded = false
        generation &+= 1
    }

    /// A read begun at `generation` finished. False (and nothing changes) when the switches changed since it began.
    @discardableResult
    mutating func finish(generation started: Int) -> Bool {
        guard started == generation else { return false }
        loaded = true
        return true
    }

    /// The draft after a (re)read: it follows the new record only while it still shows the value it was last seeded
    /// with; an edited draft is kept.
    static func reseeded<T: Equatable>(draft: T, seededWith: T, record: T) -> T {
        draft == seededWith ? record : draft
    }
}

extension Operative {
    /// RULEBOOK 1.26.1 §8 `CanonicalBusinessEngine.payEditorStartingValues(row, profile, { privatePay })` for a catalogue
    /// `operatives` row: `payProfiles/{documentId}` laid over the row while `privatePay` is on; the row exactly as stored
    /// while it is off, or when there is no profile (`self` unchanged).
    func payShown(with profile: [String: Any]?, privatePay: Bool) -> Operative {
        let person: [String: Any] = [
            "payBasis": payBasis.map { $0 as Any } ?? NSNull(),
            "dayRate": dayRate.map { $0 as Any } ?? NSNull(),
            "hourlyRate": hourlyRate.map { $0 as Any } ?? NSNull(),
        ]
        guard let answer = CanonicalBusinessEngine.payEditorStartingValues(
            person: person,
            profileId: documentId,
            profile: profile.flatMap { FirebaseBackend.firestoreJSON($0) as? [String: Any] },
            privatePay: privatePay
        ), answer.fromPayProfile else { return self }
        func number(_ key: String) -> Double? { (answer.record[key] as? NSNumber)?.doubleValue }
        let basis = (answer.record["payBasis"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var out = self
        out.payBasis = basis.isEmpty ? nil : basis
        out.dayRate = number("dayRate")
        out.hourlyRate = number("hourlyRate")
        return out
    }
}

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.26.1 §8 `payEditorStartingValues(person, parsePayProfileDocument(profileId, profile), { privatePay })`
    /// → its `record` and whether it came from the pay profile (`source`). Nil when the script did not answer.
    nonisolated static func payEditorStartingValues(
        person: [String: Any],
        profileId: String,
        profile: [String: Any]?,
        privatePay: Bool
    ) -> (record: [String: Any], fromPayProfile: Bool)? {
        var parsed: Any = NSNull()
        if let profile {
            guard let row = callJSON("parsePayProfileDocument", arguments: [profileId, profile]) else { return nil }
            parsed = row
        }
        guard let answer = callJSON("payEditorStartingValues", arguments: [person, parsed, ["privatePay": privatePay]]) as? [String: Any],
              let record = answer["record"] as? [String: Any] else { return nil }
        return (record, (answer["source"] as? String) == "payProfile")
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
        let overlaid = await payEditorRecord(for: subject)
        if overlaid != subject, let index = organizationUsers.firstIndex(where: { $0.id == subject.id }) {
            organizationUsers[index] = overlaid
        }
        return overlaid
    }

    /// RULEBOOK 1.26.1 §8: the record a pay editor starts from AND saves against
    /// (`CanonicalBusinessEngine.payEditorStartingValues`, through `AppUser.payShown`). With `privatePay` off it is
    /// `subject` itself and no pay profile is read. With it on: `payProfiles/{subject.id}`, else of a `formerUserIds`
    /// id (an invited person's pay sits on the placeholder's profile, web `payEditorRecord`); a refused or missing read
    /// keeps the stored document.
    func payEditorRecord(for subject: AppUser) async -> AppUser {
        guard SecuritySwitchContext.privatePay, let firebaseBackend else { return subject }
        for id in [subject.id] + subject.formerUserIds where !id.isEmpty {
            if let profile = await firebaseBackend.loadPayProfile(subjectId: id) {
                return subject.payShown(with: profile, profileId: id, privatePay: SecuritySwitchContext.privatePay)
            }
        }
        return subject
    }
}
