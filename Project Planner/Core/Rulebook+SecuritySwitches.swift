//
//  Rulebook+SecuritySwitches.swift
//  Project Planner
//
//  RULEBOOK 1.26.0 §8, §16, §17, §18 "Security switches" (web `lib/canonical/platformConfig.ts`, `payProfile.ts`): the
//  `enforcedReads` and `privatePay` switches on `platformConfig/app`, read per organisation with
//  `CanonicalBusinessEngine` `securitySwitches(config, orgId)`, and the pay helpers the switches change
//  (`sharedDocumentPayWrite`, `rateHistoryQueryPlan`, `payProfileReadPlan`). With both switches off every plan and
//  write is the one the app used before 1.26.0.
//

import Foundation
import FirebaseAuth
@preconcurrency import FirebaseFirestore

extension Notification.Name {
    /// A security switch changed for the open organisation (`securitySwitches`): pay reads and the read plans re-plan.
    static let securitySwitchesDidChange = Notification.Name("securitySwitchesDidChange")
}

/// The `platformConfig/app` document as last read (launch, foreground and its live listener), and the two switches for
/// the open organisation. App plumbing: the decision is `CanonicalBusinessEngine.securitySwitches`.
nonisolated enum SecuritySwitchContext {
    nonisolated(unsafe) private static var config: [String: Any]?
    nonisolated(unsafe) private static var configKey = "none"
    private static let lock = NSLock()
    private static let memo = RulebookAnswerMemo<String, SecuritySwitchState>(limit: 32)

    /// Both switches for one organisation. `nil` config (not read yet, missing document, unanswered script) is off.
    static func switches(organizationId: String?) -> SecuritySwitchState {
        lock.lock()
        let current = config
        let key = configKey
        lock.unlock()
        let orgId = organizationId ?? ""
        return memo.value(for: "\(key)|\(orgId)") {
            CanonicalBusinessEngine.securitySwitches(config: current, organizationId: orgId)
        } ?? SecuritySwitchState(enforcedReads: false, privatePay: false)
    }

    /// The open organisation's switches (`OrganizationRulebookContext.organizationId`).
    static var current: SecuritySwitchState { switches(organizationId: OrganizationRulebookContext.organizationId) }
    static var enforcedReads: Bool { current.enforcedReads }
    static var privatePay: Bool { current.privatePay }

    /// A new read of `platformConfig/app` (plain JSON; nil when the document is missing). When the open organisation's
    /// switches change, the read plans re-plan (`jobReadPlanDidChange`) and pay screens reload
    /// (`securitySwitchesDidChange`).
    static func update(config next: [String: Any]?) {
        let before = current
        let nextKey = next.flatMap { CanonicalBusinessEngine.rulebookMemoKey($0) } ?? "none"
        lock.lock()
        config = next
        configKey = nextKey
        lock.unlock()
        guard current != before else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .securitySwitchesDidChange, object: nil)
            NotificationCenter.default.post(name: .jobReadPlanDidChange, object: nil)
        }
    }

    /// Tests: forget the document.
    static func reset() {
        lock.lock()
        config = nil
        configKey = "none"
        lock.unlock()
    }
}

nonisolated struct SecuritySwitchState: Equatable, Hashable, Sendable {
    let enforcedReads: Bool
    let privatePay: Bool
}

extension CanonicalBusinessEngine {
    /// RULEBOOK 1.26.0 §18 `securitySwitches(config, organizationId)`: each switch is on when its field is exactly `true`,
    /// or the organisation's id (exact case) is in its list. Anything else — a missing document, a string, a list that is
    /// not an array of strings — is off. Nil when the script did not answer.
    nonisolated static func securitySwitches(config: [String: Any]?, organizationId: String) -> SecuritySwitchState? {
        guard let row = callJSON("securitySwitches", arguments: [config.map { $0 as Any } ?? NSNull(), organizationId]) as? [String: Any] else {
            return nil
        }
        return SecuritySwitchState(
            enforcedReads: row["enforcedReads"] as? Bool ?? false,
            privatePay: row["privatePay"] as? Bool ?? false
        )
    }

    /// RULEBOOK 1.26.0 §8 `sharedDocumentPayWrite(write, { privatePay })`: the part of a `users` / `operatives` /
    /// `managers` write that may go on that shared document — the write unchanged while `privatePay` is off; every
    /// `PAY_PROFILE_FIELDS` key left out while it is on. Native Firestore values (sentinels, Timestamps) are kept: only
    /// the key list goes to the script. The write unchanged when the script did not answer and the switch is off; with
    /// the switch on and no answer, every pay key is left out (`PAY_PROFILE_FIELDS` as read from the script, else the
    /// six named in §8).
    nonisolated static func sharedDocumentPayWrite(_ write: [String: Any], privatePay: Bool) -> [String: Any] {
        guard privatePay else { return write }
        var probe: [String: Any] = [:]
        for key in write.keys { probe[key] = true }
        let kept: Set<String>
        if let answer = callJSON("sharedDocumentPayWrite", arguments: [probe, ["privatePay": true]]) as? [String: Any] {
            kept = Set(answer.keys)
        } else {
            let pay = Set(constant("PAY_PROFILE_FIELDS", as: [String].self) ?? [
                "payBasis", "dayRate", "hourlyRate", "employmentType", "employmentTypeTransitionFrom", "employmentTypeEffectiveAt",
            ])
            kept = Set(write.keys).subtracting(pay)
        }
        return write.filter { kept.contains($0.key) }
    }

    /// `rateHistoryQueryPlan(viewer, subjects, roster, { privatePay })` → `{ kind: 'all' }` or `{ kind: 'people', userIds }`.
    nonisolated static func rateHistoryQueryPlan(
        viewer: [String: Any]?,
        subjects: [[String: Any]],
        roster: [[String: Any]],
        privatePay: Bool
    ) -> RulebookRateHistoryPlan {
        guard privatePay else { return .all }
        guard let row = callJSON(
            "rateHistoryQueryPlan",
            arguments: [viewer.map { $0 as Any } ?? NSNull(), subjects, roster, ["privatePay": true]]
        ) as? [String: Any] else {
            // No answer with the switch on: the reads the rules allow everyone (their own history only).
            return .people((viewer?["id"] as? String).map { [$0] } ?? [])
        }
        if (row["kind"] as? String) == "all" { return .all }
        return .people(row["userIds"] as? [String] ?? [])
    }

    /// `payProfileReadPlan(viewer, subjects, roster)` → `{ kind: 'all' }` or `{ kind: 'documents', ids }`.
    nonisolated static func payProfileReadPlan(viewer: [String: Any]?, subjects: [[String: Any]], roster: [[String: Any]]) -> RulebookPayProfileReadPlan {
        guard let row = callJSON(
            "payProfileReadPlan",
            arguments: [viewer.map { $0 as Any } ?? NSNull(), subjects, roster]
        ) as? [String: Any] else {
            return .documents((viewer?["id"] as? String).map { [$0] } ?? [])
        }
        if (row["kind"] as? String) == "all" { return .all }
        return .documents(row["ids"] as? [String] ?? [])
    }
}

nonisolated enum RulebookRateHistoryPlan: Equatable, Sendable {
    case all
    case people([String])
}

nonisolated enum RulebookPayProfileReadPlan: Equatable, Sendable {
    case all
    case documents([String])
}

// MARK: - Rate history and pay profiles under `privatePay` (§8)


extension FirebaseBackend {
    /// The signed-in person as `canViewPersonPay` / `rateHistoryQueryPlan` read a viewer (their roster row, the
    /// platform owner flag). Nil before the roster names them.
    var payViewerRow: [String: Any]? {
        guard let uid = currentUser?.uid,
              let me = RulebookRosterSnapshot.users.first(where: { $0.id == uid }) else { return nil }
        var row = me.payAccessSubject
        row["isPlatformOwner"] = CanonicalBusinessEngine.isPlatformOwnerEmail(me.email)
        return row
    }

    /// RULEBOOK 1.26.0 §8 `CanonicalBusinessEngine.rateHistoryQueryPlan(viewer, roster, roster, { privatePay })`: the
    /// whole `operativeDayRateHistory` collection while the switch is off (as before) or for a viewer who sees every
    /// pay; one `userId ==` query per person whose pay this viewer may see while it is on.
    var rateHistoryPlan: RulebookRateHistoryPlan {
        let roster = RulebookRosterSnapshot.users.map(\.payAccessSubject)
        return CanonicalBusinessEngine.rateHistoryQueryPlan(
            viewer: payViewerRow,
            subjects: roster,
            roster: roster,
            privatePay: SecuritySwitchContext.privatePay
        )
    }

    /// The `operativeDayRateHistory` listener a pay screen holds for `subjectId` (`listensWhileOpen`): the whole
    /// collection while the plan is `all`, else that person's rows only (a query the rules allow a pay viewer).
    func rateHistoryListenQuery(subjectId: String) -> (DocumentReference) -> Query {
        switch rateHistoryPlan {
        case .all:
            return { $0.collection("operativeDayRateHistory") }
        case .people:
            return { $0.collection("operativeDayRateHistory").whereField("userId", isEqualTo: subjectId) }
        }
    }

    /// The target suffix that makes a pay screen's history listener re-attach when the plan changes.
    var rateHistoryListenSuffix: String {
        switch rateHistoryPlan {
        case .all: return "all"
        case .people: return "people"
        }
    }

    /// RULEBOOK 1.26.0 §8: while `privatePay` is on, the roster's pay is laid over from the pay profiles this viewer may
    /// read (`payProfileReadPlan` + `overlayPayProfile`, own id, else a `formerUserIds` id). While it is off the users
    /// documents are shown unchanged — a stale pay profile left by an older build must never replace them.
    func overlayRosterPayIfPrivate(_ users: [AppUser]) async -> [AppUser] {
        guard SecuritySwitchContext.privatePay,
              let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else { return users }
        let roster = users.map(\.payAccessSubject)
        let plan = CanonicalBusinessEngine.payProfileReadPlan(viewer: payViewerRow, subjects: roster, roster: roster)
        var profiles: [String: [String: Any]] = [:]
        let collection = db.collection("organizations").document(orgId).collection("payProfiles")
        switch plan {
        case .all:
            if let snapshot = try? await collection.getDocuments() {
                for doc in snapshot.documents { profiles[doc.documentID] = doc.data() }
            }
        case .documents(let ids):
            for id in ids {
                if let snapshot = try? await collection.document(id).getDocument(), snapshot.exists, let data = snapshot.data() {
                    profiles[id] = data
                }
            }
        }
        guard !profiles.isEmpty else { return users }
        return users.map { user in
            let profile = profiles[user.id] ?? user.formerUserIds.lazy.compactMap { profiles[$0] }.first
            return profile.map { user.overlayingPayProfile($0) } ?? user
        }
    }
}
