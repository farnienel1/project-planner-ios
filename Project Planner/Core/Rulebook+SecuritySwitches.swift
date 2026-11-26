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
    /// `platformConfig/app` answered for the first time since launch (`SecuritySwitchContext.hasRead` turned true). Own
    /// pay decisions held while the switches were unknown run then (`OwnPayOverlay.swift`).
    static let securitySwitchesFirstRead = Notification.Name("securitySwitchesFirstRead")
    /// The `ghostAccounts` switch changed for the open organisation (RULEBOOK 1.34.0 §18, owner decision 7 Nov "1b"):
    /// Add user shows or hides the Ghost account toggle.
    static let ghostAccountsSwitchDidChange = Notification.Name("ghostAccountsSwitchDidChange")
    /// The `dataCheckPanel` switch changed for the open organisation (RULEBOOK 1.38.0 §27, owner change 11 Nov):
    /// Settings → Data health shows or hides the Data check panel.
    static let dataCheckPanelSwitchDidChange = Notification.Name("dataCheckPanelSwitchDidChange")
    /// The live roster (`RulebookRosterSnapshot`) changed: the catalogue operatives' pay overlay re-plans (RULEBOOK 1.27.0 §8).
    static let rulebookRosterDidChange = Notification.Name("rulebookRosterDidChange")
}

/// The `platformConfig/app` document as last read (launch, foreground and its live listener), and the two switches for
/// the open organisation. App plumbing: the decision is `CanonicalBusinessEngine.securitySwitches`.
nonisolated enum SecuritySwitchContext {
    nonisolated(unsafe) private static var config: [String: Any]?
    nonisolated(unsafe) private static var configKey = "none"
    nonisolated(unsafe) private static var hasAnswered = false
    private static let lock = NSLock()
    private static let memo = RulebookAnswerMemo<String, SecuritySwitchState>(limit: 32)
    private static let ghostMemo = RulebookAnswerMemo<String, Bool>(limit: 32)

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

    /// Whether `platformConfig/app` has been read (or confirmed missing) since launch. RULEBOOK 1.40.0 (review r306):
    /// a leave balance waits for it, so it is never worked out on "privatePay off" before the switch is known.
    static var hasRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasAnswered
    }

    /// RULEBOOK 1.34.0 §18 (owner decision 7 Nov "1b"): `ghostAccountsEnabled(platformConfig/app, organizationId)` —
    /// whether the Ghost account toggle may show. Not read yet, a missing document or an unanswered script is off.
    /// A screen switch only: existing ghosts never depend on it.
    static func ghostAccountsEnabled(organizationId: String?) -> Bool {
        lock.lock()
        let current = config
        let key = configKey
        lock.unlock()
        let orgId = organizationId ?? ""
        return ghostMemo.value(for: "\(key)|\(orgId)") {
            CanonicalBusinessEngine.ghostAccountsEnabled(config: current, organizationId: orgId)
        } ?? false
    }

    private static let ownLeaveMemo = RulebookAnswerMemo<String, Bool>(limit: 32)

    /// RULEBOOK 1.56.0 §9, §18 (owner decisions 17 Nov): `operativeOwnLeaveEnabled(platformConfig/app, organizationId)`
    /// — whether operatives read only their own leave (`leaveQueryPlan`). Not read yet, a missing document or an
    /// unanswered script is off: everyone then reads the whole `holidayBookings` collection, as before 1.56.0.
    static func operativeOwnLeaveEnabled(organizationId: String?) -> Bool {
        lock.lock()
        let current = config
        let key = configKey
        lock.unlock()
        let orgId = organizationId ?? ""
        return ownLeaveMemo.value(for: "\(key)|\(orgId)") {
            CanonicalBusinessEngine.operativeOwnLeaveEnabled(config: current, organizationId: orgId)
        } ?? false
    }

    /// The open organisation's `operativeOwnLeave` switch.
    static var operativeOwnLeave: Bool { operativeOwnLeaveEnabled(organizationId: OrganizationRulebookContext.organizationId) }

    /// The open organisation's `ghostAccounts` switch.
    static var ghostAccounts: Bool { ghostAccountsEnabled(organizationId: OrganizationRulebookContext.organizationId) }

    /// RULEBOOK 1.38.0 §27 (owner change 11 Nov): `dataCheckPanelEnabled(platformConfig/app, organizationId)` — whether
    /// the Data check panel may show. Missing / not read / unanswered is off. The check itself always runs silently.
    static var dataCheckPanel: Bool {
        lock.lock()
        let current = config
        lock.unlock()
        return CanonicalBusinessEngine.dataCheckPanelEnabled(
            config: current,
            organizationId: OrganizationRulebookContext.organizationId ?? ""
        ) ?? false
    }

    /// A new read of `platformConfig/app` (plain JSON; nil when the document is missing). When the open organisation's
    /// switches change, the read plans re-plan (`jobReadPlanDidChange`) and pay screens reload
    /// (`securitySwitchesDidChange`).
    static func update(config next: [String: Any]?) {
        let before = current
        let ghostBefore = ghostAccounts
        let panelBefore = dataCheckPanel
        let ownLeaveBefore = operativeOwnLeave
        let nextKey = next.flatMap { CanonicalBusinessEngine.rulebookMemoKey($0) } ?? "none"
        lock.lock()
        let firstAnswer = !hasAnswered
        config = next
        configKey = nextKey
        hasAnswered = true
        lock.unlock()
        if firstAnswer {
            // `switchesChanged`: `securitySwitchesDidChange` follows and starts the pay overlays, so the first answer
            // starts them once (review of #240).
            let changed = current != before
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .securitySwitchesFirstRead,
                    object: nil,
                    userInfo: ["switchesChanged": changed]
                )
            }
        }
        if dataCheckPanel != panelBefore {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dataCheckPanelSwitchDidChange, object: nil)
            }
        }
        if operativeOwnLeave != ownLeaveBefore {
            // RULEBOOK 1.56.0: the annual-leave listener re-plans (`HolidayStore`).
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .leaveReadPlanDidChange, object: nil)
            }
        }
        if ghostAccounts != ghostBefore {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ghostAccountsSwitchDidChange, object: nil)
            }
        }
        guard current != before else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .securitySwitchesDidChange, object: nil)
            NotificationCenter.default.post(name: .jobReadPlanDidChange, object: nil)
        }
    }

    /// Tests: whether `platformConfig/app` reads as answered (`hasRead`), without touching the switches.
    static func setReadForTests(_ read: Bool) {
        lock.lock()
        hasAnswered = read
        lock.unlock()
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

    /// `rateHistoryQueryPlan(viewer, subjects, roster, { privatePay })` → `{ kind: 'all' }` or `{ kind: 'people', userIds,
    /// operativeIds }`. 1.27.0: `operativeIds` are the catalogue operatives among `subjects`
    /// (`catalogueOperativePaySubjects`) whose pay the viewer may see; absent in older scripts, read as `[]`.
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
        return .people(row["userIds"] as? [String] ?? [], operativeIds: row["operativeIds"] as? [String] ?? [])
    }

    /// RULEBOOK 1.27.0 §8 `catalogueOperativePaySubjects(operatives, roster)`: the `operatives` rows with no app account
    /// (no `linkedUserId` / `userId` / `uid`, a row id that is no roster member's id, no roster member on the row's
    /// email), each as a pay subject `{ id: <row id>, email, catalogueOperative: true }` for `canViewPersonPay`,
    /// `payProfileReadPlan` and `rateHistoryQueryPlan`. Empty when the script did not answer (nothing extra is read).
    nonisolated static func catalogueOperativePaySubjects(operatives: [[String: Any]], roster: [[String: Any]]) -> [[String: Any]] {
        guard !operatives.isEmpty else { return [] }
        return callJSON("catalogueOperativePaySubjects", arguments: [operatives, roster]) as? [[String: Any]] ?? []
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
    /// One `userId ==` query per account holder; 1.27.0: one `operativeId ==` + `userId == ''` query per catalogue
    /// operative row id in `operativeIds`.
    case people([String], operativeIds: [String] = [])
}

extension Operative {
    /// This `operatives` row as `catalogueOperativePaySubjects` reads it (RULEBOOK 1.27.0 §8).
    var catalogueOperativeRow: [String: Any] {
        [
            "id": documentId,
            "email": email,
            "linkedUserId": linkedUserId.map { $0 as Any } ?? NSNull(),
            "isActive": isActive,
        ]
    }
}

/// The live `operatives` rows (`OperativeStore`), for the pay plans that need the catalogue operatives (RULEBOOK 1.27.0
/// §8) without a store at hand — as `RulebookRosterSnapshot` holds the roster.
enum RulebookCatalogueOperativeSnapshot {
    private(set) static var rows: [[String: Any]] = []
    private static var key: [String] = []

    static func update(_ operatives: [Operative]) {
        let next = operatives.map { "\($0.documentId)|\($0.email)|\($0.linkedUserId ?? "")|\($0.isActive)" }
        guard next != key else { return }
        key = next
        rows = operatives.map(\.catalogueOperativeRow)
    }
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

    /// RULEBOOK 1.26.0 §8 `CanonicalBusinessEngine.rateHistoryQueryPlan(viewer, subjects, roster, { privatePay })`: the
    /// whole `operativeDayRateHistory` collection while the switch is off (as before) or for a viewer who sees every
    /// pay; one `userId ==` query per person whose pay this viewer may see while it is on. 1.27.0: the subjects are the
    /// roster plus the catalogue operatives (`catalogueOperativePaySubjects`), so an operatives manager also gets one
    /// `operativeId ==` + `userId == ''` query per catalogue row. Nothing extra is computed while the switch is off.
    var rateHistoryPlan: RulebookRateHistoryPlan {
        let privatePay = SecuritySwitchContext.privatePay
        guard privatePay else { return .all }
        let roster = RulebookRosterSnapshot.users.map(\.payAccessSubject)
        let catalogue = CanonicalBusinessEngine.catalogueOperativePaySubjects(
            operatives: RulebookCatalogueOperativeSnapshot.rows,
            roster: roster
        )
        return CanonicalBusinessEngine.rateHistoryQueryPlan(
            viewer: payViewerRow,
            subjects: roster + catalogue,
            roster: roster,
            privatePay: privatePay
        )
    }

    /// The `operativeDayRateHistory` listener a pay screen holds for `subjectId` (`listensWhileOpen`): the whole
    /// collection while the plan is `all`, else that person's rows only (a query the rules allow a pay viewer). 1.27.0:
    /// a catalogue operative row id in the plan's `operativeIds` listens to `operativeId ==` + `userId == ''` (the only
    /// such query the rules allow); account holders keep `userId ==`.
    func rateHistoryListenQuery(subjectId: String) -> (DocumentReference) -> Query {
        switch rateHistoryPlan {
        case .all:
            return { $0.collection("operativeDayRateHistory") }
        case .people(_, let operativeIds):
            if operativeIds.contains(subjectId) {
                return Self.catalogueRateHistoryQuery(operativeId: subjectId)
            }
            return { $0.collection("operativeDayRateHistory").whereField("userId", isEqualTo: subjectId) }
        }
    }

    /// RULEBOOK 1.27.0 §8: a catalogue operative's rate history — `operativeId ==` its row id and `userId == ''` (rows
    /// `payRateHistoryWriteFields` wrote for a row with no account). A plain `operativeId ==` query is refused by the rules.
    nonisolated static func catalogueRateHistoryQuery(operativeId: String) -> (DocumentReference) -> Query {
        { $0.collection("operativeDayRateHistory").whereField("operativeId", isEqualTo: operativeId).whereField("userId", isEqualTo: "") }
    }

    /// RULEBOOK §1 `LIVE_COLLECTIONS` ("Pay history `operativeDayRateHistory` listens while open") and 1.26.0 / 1.27.0 §8
    /// `rateHistoryQueryPlan`: the listeners one person's pay-history screen (Edit User) holds, mirroring web
    /// `watchOperativeDayRateHistory`. Plan `all`: the whole collection (one listener). Plan `people`: one `userId ==`
    /// listener per id the person goes by that the plan lists (the plan's stored id, matched without case), and one
    /// `operativeId ==` + `userId == ''` listener per `operatives` row of the person that the plan lists as a catalogue
    /// operative. A person whose pay this viewer may not see gets none (nothing is read). Keys are stable per query, so a
    /// plan change re-attaches only what changed.
    nonisolated static func rateHistoryPersonListenQueries(
        plan: RulebookRateHistoryPlan,
        userIds: [String],
        operativeRowIds: [String]
    ) -> [(key: String, query: (DocumentReference) -> Query)] {
        switch plan {
        case .all:
            return [(key: "all", query: { $0.collection("operativeDayRateHistory") })]
        case .people(let planUserIds, let planOperativeIds):
            func planIds(_ wanted: [String], in listed: [String]) -> [String] {
                let keys = Set(wanted.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
                var seen = Set<String>()
                return listed.filter { keys.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) && seen.insert($0).inserted }
            }
            var out: [(key: String, query: (DocumentReference) -> Query)] = []
            for id in planIds(userIds, in: planUserIds) {
                out.append((key: "u:\(id)", query: { $0.collection("operativeDayRateHistory").whereField("userId", isEqualTo: id) }))
            }
            for id in planIds(operativeRowIds, in: planOperativeIds) {
                out.append((key: "o:\(id)", query: catalogueRateHistoryQuery(operativeId: id)))
            }
            return out
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
        await overlayRosterPayIfPrivateResult(users).users
    }

    /// `overlayRosterPayIfPrivate` with what it read: the pay profiles by document id (so the next roster snapshot can be
    /// laid over at once, `layingRosterPayProfiles`) and whether a read failed or was refused. A failed read is never
    /// "no profile" (review of #240): the caller marks the roster's pay not ready and retries.
    func overlayRosterPayIfPrivateResult(_ users: [AppUser]) async -> RosterPayOverlayResult {
        guard SecuritySwitchContext.privatePay,
              let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else {
            return RosterPayOverlayResult(users: users, profiles: [:], failedUserIds: [])
        }
        let roster = users.map(\.payAccessSubject)
        let plan = CanonicalBusinessEngine.payProfileReadPlan(viewer: payViewerRow, subjects: roster, roster: roster)
        var profiles: [String: [String: Any]] = [:]
        var failedProfileIds = Set<String>()
        var everyoneFailed = false
        var fromCache = false
        let collection = db.collection("organizations").document(orgId).collection("payProfiles")
        switch plan {
        case .all:
            // The server's answer, never a partial cache copy (review of #240); the cache only when offline.
            do {
                let snapshot = try await collection.getDocuments(source: .server)
                for doc in snapshot.documents { profiles[doc.documentID] = doc.data() }
            } catch {
                let ns = error as NSError
                NSLog("PAY_PROFILE_ROSTER_READ_FAILED org=%@ %@", orgId, error.localizedDescription)
                if Self.payProfileReadErrorIsOffline(domain: ns.domain, code: ns.code),
                   let cached = try? await collection.getDocuments(source: .cache) {
                    for doc in cached.documents { profiles[doc.documentID] = doc.data() }
                    fromCache = true
                } else {
                    everyoneFailed = true
                }
            }
        case .documents(let ids):
            for id in ids {
                do {
                    let snapshot = try await collection.document(id).getDocument(source: .server)
                    if snapshot.exists, let data = snapshot.data() { profiles[id] = data }
                } catch {
                    let ns = error as NSError
                    NSLog("PAY_PROFILE_ROSTER_READ_FAILED org=%@ id=%@ %@", orgId, id, error.localizedDescription)
                    if Self.payProfileReadErrorIsOffline(domain: ns.domain, code: ns.code),
                       let cached = try? await collection.document(id).getDocument(source: .cache) {
                        if cached.exists, let data = cached.data() { profiles[id] = data }
                        fromCache = true
                    } else {
                        failedProfileIds.insert(id)
                    }
                }
            }
        }
        return RosterPayOverlayResult(
            users: Self.layingRosterPayProfiles(users, profiles: profiles),
            profiles: profiles,
            failedUserIds: everyoneFailed
                ? Set(users.map { $0.id.lowercased() })
                : Self.rosterFailedUserIds(users, profiles: profiles, failedProfileIds: failedProfileIds),
            fromCache: fromCache
        )
    }

    /// The people whose pay could not be read: a read of one of their ids failed and none of their ids answered with a
    /// profile. User ids, lower case.
    static func rosterFailedUserIds(
        _ users: [AppUser],
        profiles: [String: [String: Any]],
        failedProfileIds: Set<String>
    ) -> Set<String> {
        guard !failedProfileIds.isEmpty else { return [] }
        var out = Set<String>()
        for user in users {
            let ids = [user.id] + user.formerUserIds
            if ids.contains(where: { profiles[$0] != nil }) { continue }
            if ids.contains(where: failedProfileIds.contains) { out.insert(user.id.lowercased()) }
        }
        return out
    }

    /// The roster with each person's pay profile laid over (`payShown`, RULEBOOK 1.26.1 §8: own id, else a
    /// `formerUserIds` id). Rows with no profile in `profiles` are returned as given.
    static func layingRosterPayProfiles(_ users: [AppUser], profiles: [String: [String: Any]]) -> [AppUser] {
        guard !profiles.isEmpty else { return users }
        return users.map { user in
            let profileId = ([user.id] + user.formerUserIds).first { profiles[$0] != nil }
            return profileId.map { user.payShown(with: profiles[$0], profileId: $0, privatePay: true) } ?? user
        }
    }

    /// RULEBOOK 1.27.0 §8 (owner decision 7): while `privatePay` is on, each catalogue `operatives` row
    /// (`catalogueOperativePaySubjects` over `roster`) whose pay this viewer may see is laid over from
    /// `payProfiles/{rowId}` (`payProfileReadPlan` with the roster plus the catalogue subjects, then
    /// `Operative.payShown`). Admins read the collection; an operatives manager reads each catalogue row's profile by id.
    /// Each read stands alone: a refused or missing one keeps that row as stored. While the switch is off nothing is read
    /// and the rows are returned unchanged.
    func overlayCatalogueOperativePayIfPrivate(_ operatives: [Operative], roster users: [AppUser]) async -> [Operative] {
        await overlayCatalogueOperativePayWithStatus(operatives, roster: users).rows
    }

    /// `overlayCatalogueOperativePayIfPrivate` with what the read covered (web #347 item 4,
    /// `payProfilesStatusForCatalogueOperative`): `planned` — the catalogue row ids (lower case) whose `payProfiles`
    /// document this viewer's plan read; `failed` — those whose read failed (refused or no answer; a missing document is
    /// not a failure). `complete` is false when nothing could be planned (no open organisation), so a report keeps
    /// waiting. While `privatePay` is off nothing is read and the result is complete with nothing planned.
    func overlayCatalogueOperativePayWithStatus(
        _ operatives: [Operative],
        roster users: [AppUser]
    ) async -> CataloguePayOverlayResult {
        guard SecuritySwitchContext.privatePay, !operatives.isEmpty else {
            return CataloguePayOverlayResult(rows: operatives, planned: [], failed: [], complete: true)
        }
        guard let orgId = currentOrganization?.firestoreDocumentId, !orgId.isEmpty else {
            return CataloguePayOverlayResult(rows: operatives, planned: [], failed: [], complete: false)
        }
        let roster = users.map(\.payAccessSubject)
        let catalogue = CanonicalBusinessEngine.catalogueOperativePaySubjects(
            operatives: operatives.map(\.catalogueOperativeRow),
            roster: roster
        )
        let catalogueIds = Set(catalogue.compactMap { $0["id"] as? String })
        guard !catalogueIds.isEmpty else {
            return CataloguePayOverlayResult(rows: operatives, planned: [], failed: [], complete: true)
        }
        let plan = CanonicalBusinessEngine.payProfileReadPlan(viewer: payViewerRow, subjects: roster + catalogue, roster: roster)
        var profiles: [String: [String: Any]] = [:]
        var planned = Set<String>()
        var failed = Set<String>()
        let collection = db.collection("organizations").document(orgId).collection("payProfiles")
        switch plan {
        case .all:
            planned = Set(catalogueIds.map { $0.lowercased() })
            if let snapshot = try? await collection.getDocuments() {
                for doc in snapshot.documents where catalogueIds.contains(doc.documentID) { profiles[doc.documentID] = doc.data() }
            } else {
                failed = planned
            }
        case .documents(let ids):
            for id in ids where catalogueIds.contains(id) {
                planned.insert(id.lowercased())
                do {
                    let snapshot = try await collection.document(id).getDocument()
                    if snapshot.exists, let data = snapshot.data() { profiles[id] = data }
                } catch {
                    failed.insert(id.lowercased())
                }
            }
        }
        var rows = operatives
        if !profiles.isEmpty {
            rows = operatives.map { row -> Operative in
                guard let profile = profiles[row.documentId] else { return row }
                return row.payShown(with: profile, privatePay: true)
            }
        }
        return CataloguePayOverlayResult(rows: rows, planned: planned, failed: failed, complete: true)
    }
}

/// What one catalogue operatives' pay overlay read (web #347 item 4). See
/// `FirebaseBackend.overlayCatalogueOperativePayWithStatus`.
struct CataloguePayOverlayResult {
    var rows: [Operative]
    /// Catalogue row ids (lower case) whose `payProfiles` document the viewer's plan read.
    var planned: Set<String>
    /// Planned ids whose read failed (no good copy laid over).
    var failed: Set<String>
    /// False when no read could be planned (no open organisation).
    var complete: Bool
}
