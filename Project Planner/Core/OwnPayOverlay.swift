//
//  OwnPayOverlay.swift
//  Project Planner
//
//  RULEBOOK 1.26.0 / 1.26.1 §8 ("Who may see pay"; `CanonicalBusinessEngine.payEditorStartingValues`,
//  `overlayPayProfile`): while `privatePay` is on, pay — rates, pay basis and the employment type with its dates — is
//  read from `payProfiles/{id}`, because the strip removes it from `users/{uid}`. The roster is laid over by
//  `UserStore.schedulePrivatePayOverlay`; this file does the same for the signed-in person's own record
//  (`UserStore.currentUserWithPay`, and so `displayUser`): own id first, then a `formerUserIds` id, exactly as the roster
//  overlay and My Profile pick it. While `privatePay` is off nothing is read and the users document is used as stored.
//
//  It also tells pay screens when the overlays are ready (`PrivatePayOverlayReadiness`), so nothing is signed,
//  counter-signed, invoiced, exported or reported on a stripped record, and nothing is decided before
//  `platformConfig/app` has said whether `privatePay` is on (`SecuritySwitchContext.hasRead`). A failed or refused read
//  is never "no profile": the last good record is kept, else the decision waits. App plumbing only: every pay rule
//  stays in the packed script.
//

import Foundation
import Combine
@preconcurrency import FirebaseFirestore

/// Whether one pay-profile overlay can be priced from.
enum PayOverlayLoad: Equatable {
    case ready
    case loading
    case failed
}

/// Whose pay a screen prices: the viewer's own (My Timesheets), the team as a whole (User Timesheets list and bulk
/// Export, the weekly report) or one person (their review, invoice, Export row or PDF). Each waits only for what it
/// needs: one person's failed pay-profile read blocks only that person's screens.
enum PayOverlayScope: Equatable {
    case ownPay
    case othersPay
    /// One person: every id they go by (lower case) and the name the message shows.
    case person(ids: [String], name: String)

    /// The scope of `user`'s screens: their id, former ids and same-email ids.
    static func forPerson(_ user: AppUser) -> PayOverlayScope {
        let ids = ([user.id] + user.formerUserIds + user.sameEmailUserIds).map { $0.lowercased() }
        let name = user.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return .person(ids: ids, name: name.isEmpty ? user.email : name)
    }
}

/// What one roster overlay read: the roster laid over, the profiles by document id, the people (roster user ids, lower
/// case) whose pay-profile read failed or was refused, and whether anything was answered from this phone's cache
/// (offline) — such an answer is shown but never kept as the last good overlay.
struct RosterPayOverlayResult {
    var users: [AppUser]
    var profiles: [String: [String: Any]]
    var failedUserIds: Set<String>
    var fromCache: Bool = false

    var failed: Bool { !failedUserIds.isEmpty }
}

/// The last good roster overlay (`UserStore.rosterPaySubjectsKey`: organisation, viewer and the people's ids), and the
/// people whose read failed in it (never laid over from it).
struct RosterPayProfileCache {
    var key: String
    var profiles: [String: [String: Any]]
    var failedIds: Set<String> = []
    /// Organisation and viewer the profiles were read for (`UserStore.rosterPayScopeKey`).
    var scope: String = ""
}

/// The six pay fields of a roster row (`withPayFields`), comparable, so pay this store laid over can be told apart from
/// what the users document holds.
struct RosterPayFields: Equatable {
    var payBasis: String?
    var dayRate: Double?
    var hourlyRate: Double?
    var employmentType: EmploymentType
    var employmentTypeTransitionFrom: EmploymentType?
    var employmentTypeEffectiveAt: Date?

    init(_ user: AppUser) {
        payBasis = user.payBasis
        dayRate = user.dayRate
        hourlyRate = user.hourlyRate
        employmentType = user.employmentType
        employmentTypeTransitionFrom = user.employmentTypeTransitionFrom
        employmentTypeEffectiveAt = user.employmentTypeEffectiveAt
    }

    func applied(to user: AppUser) -> AppUser {
        var out = user
        out.payBasis = payBasis
        out.dayRate = dayRate
        out.hourlyRate = hourlyRate
        out.employmentType = employmentType
        out.employmentTypeTransitionFrom = employmentTypeTransitionFrom
        out.employmentTypeEffectiveAt = employmentTypeEffectiveAt
        return out
    }
}

/// Pay-profile writes waiting for their batch to commit. A committed write posts `.payProfileSaved` (subject id and the
/// fields written), so the saver's own pay is read again and the roster's last good overlay takes the saved values —
/// never an older profile laid back over the edited row (review of #240).
@MainActor
enum PayProfileSaveRegistry {
    private static var pending: [ObjectIdentifier: [(subjectId: String, fields: [String: Any])]] = [:]

    static func note(_ batch: WriteBatch, subjectId: String, fields: [String: Any]) {
        pending[ObjectIdentifier(batch), default: []].append((subjectId, fields))
    }

    static func committed(_ batch: WriteBatch) {
        let saves = pending.removeValue(forKey: ObjectIdentifier(batch)) ?? []
        for save in saves {
            NotificationCenter.default.post(
                name: .payProfileSaved,
                object: nil,
                userInfo: ["subjectId": save.subjectId, "fields": save.fields]
            )
        }
    }

    static func discard(_ batch: WriteBatch) {
        pending.removeValue(forKey: ObjectIdentifier(batch))
    }
}

extension Notification.Name {
    /// A pay-profile write committed (`PayProfileSaveRegistry`): userInfo `subjectId`, `fields`.
    static let payProfileSaved = Notification.Name("payProfileSaved")
}

/// Whether a report may be built from the people's pay (`PrivatePayOverlayReadiness.reportGate`).
struct ReportPayGate: Equatable {
    var status: PayOverlayLoad
    /// What the screen shows instead of the report: nil when ready, or while the organisation itself loads.
    var message: String?
}

/// Reads `payProfiles` documents (the own-pay overlay). `FirebaseBackend` in the app; a fake in tests.
@MainActor
protocol PayProfileReading: AnyObject {
    func cachedPayProfile(organizationId: String, subjectId: String) async -> [String: Any]?
    func readPayProfile(organizationId: String, subjectId: String, cacheWhenOffline: Bool) async -> PayProfileRead
}

/// The signed-in person's pay profile read for one key (organisation, person and their former ids).
struct OwnPayOverlayState: Equatable {
    /// `UserStore.ownPayKey` of the record this state was read for ("" = nothing read).
    var key: String = ""
    /// True once every read for `key` has answered (or given up).
    var finished = false
    /// False when the person's own `payProfiles/{uid}` read was refused or failed (never "no profile").
    var readable = true
    /// The person with their pay profile laid over (`AppUser.payShown`), or nil when no profile was read.
    var record: AppUser?
    /// True when `record` came from a finished read (the server, or this phone's copy while offline). False for the
    /// copy shown from the cache at launch while the server read runs (dropped if the server refuses it).
    var recordConfirmed = false
    /// True when the last finished read was answered from this phone's cache (offline): shown, never priced or signed
    /// from, and read again on foreground or when the phone is back online.
    var answeredFromCache = false
}

/// Whether the private-pay overlays are ready. Pay screens wait for it through `PayInputsLoad.blockMessage`. Set only by
/// `UserStore`; `platformConfig/app` not read yet always waits.
@MainActor
enum PrivatePayOverlayReadiness {
    static let loadingMessage = "Loading pay details…"
    static let ownFailedMessage = "Your pay details could not be loaded, so pay cannot be worked out. Check your connection and try again."
    /// The hub while the phone is offline and the person's own pay is not known.
    static let ownOfflineMessage = "Connect to the internet to load your pay details."
    static func personFailedMessage(_ name: String) -> String {
        "Pay details for \(name) could not be loaded, so their pay cannot be worked out. Check your connection and try again."
    }
    /// Export: the people left out because their pay details could not be loaded.
    static let exportSkippedMessage = "pay details could not be loaded, so not exported. Try again."
    static let rosterFailedMessage = "Pay details for the team could not be loaded, so pay cannot be worked out. Check your connection and try again."
    /// The weekly report and the Payrun Snapshot (web #342 `reportPayGate`): the organisation could not be read.
    static let reportFailedMessage = "Could not load pay details, so this report cannot be built yet. Try again."
    static func reportPeopleFailedMessage(_ names: [String]) -> String {
        "Could not load pay details for \(names.joined(separator: ", ")), so this report cannot be built yet. Try again."
    }

    private(set) static var own: PayOverlayLoad = .ready
    private(set) static var roster: PayOverlayLoad = .ready
    /// Roster people (user ids, lower case) whose pay-profile read failed with no good copy held.
    private(set) static var failedPersonIds: Set<String> = []
    /// Their names, sorted (the weekly report names them).
    private(set) static var failedPersonNames: [String] = []
    /// True while the roster's last answer came from this phone's cache (offline).
    private(set) static var rosterFromCache = false

    static func update(
        own: PayOverlayLoad,
        roster: PayOverlayLoad,
        failedPersonIds: Set<String> = [],
        failedPersonNames: [String] = [],
        rosterFromCache: Bool = false
    ) {
        self.own = own
        self.roster = roster
        self.failedPersonIds = failedPersonIds
        self.failedPersonNames = failedPersonNames
        self.rosterFromCache = rosterFromCache
    }

    /// Back to "nothing pending" (tests, sign-out).
    static func reset() {
        update(own: .ready, roster: .ready)
    }

    /// Whether `user`'s pay could not be loaded (while `privatePay` is on): Export skips them and names them.
    static func personPayFailed(_ user: AppUser) -> Bool {
        guard let message = blockMessage(scope: .forPerson(user)) else { return false }
        return message != loadingMessage
    }

    /// Why pay cannot be worked out yet for `scope`, else nil. Before `platformConfig/app` has answered nothing is
    /// priced (the switch could be on). While `privatePay` is off nothing is read, so nothing is waited for.
    static func blockMessage(
        scope: PayOverlayScope,
        switchesKnown: Bool,
        privatePay: Bool,
        own: PayOverlayLoad,
        roster: PayOverlayLoad,
        failedPersonIds: Set<String> = [],
        failedPersonNames: [String] = [],
        rosterFromCache: Bool = false
    ) -> String? {
        guard switchesKnown else { return loadingMessage }
        guard privatePay else { return nil }
        switch scope {
        case .ownPay:
            switch own {
            case .ready: return nil
            case .loading: return loadingMessage
            case .failed: return ownFailedMessage
            }
        case .othersPay:
            // The team list waits only for the first overlay; one person's failure never blocks the rest.
            switch roster {
            case .ready: return nil
            case .loading: return loadingMessage
            case .failed: return rosterFailedMessage
            }
        case .person(let ids, let name):
            if roster == .loading { return loadingMessage }
            if roster == .failed || ids.contains(where: failedPersonIds.contains) { return personFailedMessage(name) }
            return nil
        }
    }

    /// Web #342 `reportPayGate` + `reportGatePeople`: a report that prices or labels `people` (only those it prices:
    /// the weekly report's priced people, the Payrun Snapshot's row people) is built only when each one's pay is known.
    /// The organisation loading: loading with no message (the screen shows "Loading…"). The organisation failed, or any
    /// of `people` failed: refused, naming them, with Retry. A last good server overlay that covers them is enough
    /// (offline too: rulebook §2, weekly reports are read-only offline); anyone else never blocks it.
    static func reportGate(
        people: [AppUser],
        switchesKnown: Bool,
        privatePay: Bool,
        roster: PayOverlayLoad,
        failedPersonIds: Set<String>
    ) -> ReportPayGate {
        guard switchesKnown else { return ReportPayGate(status: .loading, message: nil) }
        guard privatePay else { return ReportPayGate(status: .ready, message: nil) }
        switch roster {
        case .failed: return ReportPayGate(status: .failed, message: reportFailedMessage)
        case .loading: return ReportPayGate(status: .loading, message: nil)
        case .ready: break
        }
        var seen = Set<String>()
        let failed = people
            .filter { person in
                let ids = ([person.id] + person.formerUserIds + person.sameEmailUserIds).map { $0.lowercased() }
                return ids.contains(where: failedPersonIds.contains) && seen.insert(person.id.lowercased()).inserted
            }
            .map { $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.email : $0.fullName }
            .sorted()
        guard failed.isEmpty else { return ReportPayGate(status: .failed, message: reportPeopleFailedMessage(failed)) }
        return ReportPayGate(status: .ready, message: nil)
    }

    static func reportGate(people: [AppUser]) -> ReportPayGate {
        reportGate(
            people: people,
            switchesKnown: SecuritySwitchContext.hasRead,
            privatePay: SecuritySwitchContext.privatePay,
            roster: roster,
            failedPersonIds: failedPersonIds
        )
    }

    static func blockMessage(scope: PayOverlayScope) -> String? {
        blockMessage(
            scope: scope,
            switchesKnown: SecuritySwitchContext.hasRead,
            privatePay: SecuritySwitchContext.privatePay,
            own: own,
            roster: roster,
            failedPersonIds: failedPersonIds,
            failedPersonNames: failedPersonNames,
            rosterFromCache: rosterFromCache
        )
    }
}

extension UserStore {
    /// The key an own-pay read belongs to: the organisation, the person and their former ids. A read for another key is
    /// never laid over (an organisation switch or another sign-in starts a new read).
    static func ownPayKey(user: AppUser?, organizationId: String?) -> String {
        guard let user else { return "" }
        let org = organizationId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ([org, user.id] + user.formerUserIds).joined(separator: "|")
    }

    /// The person's pay record from their pay-profile reads, in order: own id first, then each former id (the
    /// roster overlay's order, `overlayRosterPayIfPrivate`). `readable` is the own-id read's answer. A refused read of a
    /// former id is skipped (an old invite placeholder's profile may not be readable by the person).
    static func ownPayRecord(
        user: AppUser,
        reads: [(id: String, read: Bool, data: [String: Any]?)]
    ) -> (record: AppUser?, readable: Bool) {
        let readable = reads.first { $0.id == user.id }?.read ?? false
        guard let hit = reads.first(where: { $0.read && $0.data != nil }), let data = hit.data else {
            return (nil, readable)
        }
        return (user.payShown(with: data, profileId: hit.id, privatePay: true), readable)
    }

    /// The state after the reads for `key` finished. A good read replaces everything. A failed own read keeps the last
    /// confirmed record of the same key (so a failure never puts the stripped document back); the launch cache copy is
    /// kept only when the failure was the phone being offline — after a refusal it is dropped.
    static func ownPayStateAfterRead(
        key: String,
        previous: OwnPayOverlayState,
        record: AppUser?,
        readable: Bool,
        offline: Bool,
        fromCache: Bool = false
    ) -> OwnPayOverlayState {
        if readable && fromCache {
            // This phone's copy (offline): shown, never confirmed. A record the server confirmed earlier stays.
            if previous.key == key, previous.recordConfirmed, let confirmed = previous.record {
                return OwnPayOverlayState(
                    key: key, finished: true, readable: true, record: confirmed, recordConfirmed: true, answeredFromCache: true
                )
            }
            return OwnPayOverlayState(
                key: key, finished: true, readable: true, record: record, recordConfirmed: false, answeredFromCache: true
            )
        }
        if readable {
            return OwnPayOverlayState(key: key, finished: true, readable: true, record: record, recordConfirmed: record != nil)
        }
        let samePerson = previous.key == key
        let kept = samePerson && (previous.recordConfirmed || offline) ? previous.record : nil
        return OwnPayOverlayState(
            key: key,
            finished: true,
            readable: false,
            record: kept,
            recordConfirmed: kept != nil && previous.recordConfirmed
        )
    }

    /// Whether the person's own employment type and rates can be decided on for `key` (My Timesheets, the timesheet
    /// reminder, `displayUser` decisions): a record laid over — confirmed, or the launch cache copy while the server
    /// read runs — or a finished, answered read (no profile at all). A failed read with no record is never decidable.
    static func ownPayDecidable(_ state: OwnPayOverlayState, key: String) -> Bool {
        guard state.key == key else { return false }
        // A "no profile" answered only from this phone's cache (offline) is unknown, never the stripped document.
        return state.record != nil || (state.finished && state.readable && !state.answeredFromCache)
    }

    /// Whether the person's own pay may be priced and signed for `key` (`PrivatePayOverlayReadiness`, scope `.ownPay`):
    /// only from a finished read, or a confirmed record kept while the same person is read again or after a failure.
    static func ownPayLoad(_ state: OwnPayOverlayState, key: String) -> PayOverlayLoad {
        guard state.key == key else { return .loading }
        let confirmed = state.record != nil && state.recordConfirmed
        guard state.finished else { return confirmed ? .ready : .loading }
        if confirmed { return .ready }
        // An answer from this phone's cache is not priced or signed from: wait for the server.
        if state.readable { return state.answeredFromCache ? .loading : .ready }
        return .failed
    }

    /// `user` with the own-pay record's pay fields, when the state belongs to this key and `privatePay` is on; else
    /// `user` unchanged. Only the six pay fields move (`withPayFields`); every other field stays as held. A record kept
    /// while the same person is read again stays laid over (no flicker back to the stripped document).
    static func layingOwnPay(_ state: OwnPayOverlayState, over user: AppUser, key: String, privatePay: Bool) -> AppUser {
        guard privatePay, state.key == key, let record = state.record, record.id == user.id else {
            return user
        }
        return user.withPayFields(of: record)
    }

    /// The key of the people a roster overlay priced: the organisation, the viewer (the read plan follows them) and every
    /// id of every person, lower case and sorted. A snapshot with the same key is the same set of people.
    /// The last good roster overlay with the pay fields a committed save wrote to `payProfiles/{subjectId}` merged in, so
    /// it is never laid back over the edited row with the old values.
    static func rosterPayCacheAfterSave(
        _ cache: RosterPayProfileCache?,
        subjectId: String,
        fields: [String: Any]
    ) -> RosterPayProfileCache? {
        guard var cache else { return nil }
        var profile = cache.profiles[subjectId] ?? [:]
        for (key, value) in fields { profile[key] = value }
        cache.profiles[subjectId] = profile
        cache.failedIds.remove(subjectId.lowercased())
        return cache
    }

    /// Whether a saved pay profile is the signed-in person's own (their id or a former id, without case).
    static func payProfileSaveIsOwn(subjectId: String, user: AppUser?) -> Bool {
        guard let user else { return false }
        let key = subjectId.lowercased()
        return ([user.id] + user.formerUserIds).contains { $0.lowercased() == key }
    }

    /// A committed pay-profile save (review of #240): the own pay is read again; the roster's last good overlay takes the
    /// saved values and the roster is read again.
    func payProfileSaved(subjectId: String, fields: [String: Any]) {
        if Self.payProfileSaveIsOwn(subjectId: subjectId, user: currentUser) {
            scheduleOwnPayOverlay(force: true)
        }
        if let updated = Self.rosterPayCacheAfterSave(rosterPayProfileCache, subjectId: subjectId, fields: fields) {
            rosterPayProfileCache = updated
        }
        schedulePrivatePayOverlay()
    }

    /// The organisation and viewer part of `rosterPaySubjectsKey`: profiles read for this scope may be laid over the
    /// people still present while a changed set of people is read.
    static func rosterPayScopeKey(organizationId: String, viewerId: String?) -> String {
        [organizationId, viewerId?.lowercased() ?? ""].joined(separator: "|")
    }

    static func rosterPaySubjectsKey(_ users: [AppUser], organizationId: String, viewerId: String?) -> String {
        let people = users
            .map { ([$0.id] + $0.formerUserIds).map { $0.lowercased() }.sorted().joined(separator: ",") }
            .sorted()
            .joined(separator: ";")
        return [organizationId, viewerId?.lowercased() ?? "", people].joined(separator: "|")
    }

    /// A new roster snapshot: with a good overlay of the same people, laid over from it at once and ready (its failed
    /// people stay failed); otherwise as given and loading until its overlay answers.
    /// When the people changed but the organisation and viewer did not, the last good profiles are laid over the people
    /// still present (never stripped rows for them) while the state stays loading.
    static func rosterPayAfterSnapshot(
        _ users: [AppUser],
        cache: RosterPayProfileCache?,
        key: String,
        scope: String? = nil
    ) -> (users: [AppUser], load: PayOverlayLoad, failedIds: Set<String>) {
        guard let cache else { return (users, .loading, []) }
        if cache.key == key {
            return (FirebaseBackend.layingRosterPayProfiles(users, profiles: cache.profiles), .ready, cache.failedIds)
        }
        if let scope, cache.scope == scope {
            return (FirebaseBackend.layingRosterPayProfiles(users, profiles: cache.profiles), .loading, [])
        }
        return (users, .loading, [])
    }

    /// An overlay answer for `raw`. Server answers become the new last good overlay; a person whose read failed now but
    /// was good in the last overlay of the same people keeps that copy. An answer from this phone's cache (offline) is
    /// never kept as the last good overlay: the last good one is shown when there is one, else the cache copy with
    /// every person failed (nothing about them is signed or exported until the server answers).
    static func rosterPayAfterResult(
        _ raw: [AppUser],
        result: RosterPayOverlayResult,
        cache: RosterPayProfileCache?,
        key: String,
        scope: String = ""
    ) -> (users: [AppUser], cache: RosterPayProfileCache?, failedIds: Set<String>) {
        let good = cache?.key == key ? cache : nil
        if result.fromCache {
            if let good {
                return (FirebaseBackend.layingRosterPayProfiles(raw, profiles: good.profiles), good, good.failedIds)
            }
            return (result.users, nil, Set(raw.map { $0.id.lowercased() }))
        }
        var profiles = result.profiles
        var failed = result.failedUserIds
        if let good {
            for user in raw {
                let id = user.id.lowercased()
                guard failed.contains(id), !good.failedIds.contains(id) else { continue }
                for profileId in [user.id] + user.formerUserIds where profiles[profileId] == nil {
                    if let kept = good.profiles[profileId] { profiles[profileId] = kept }
                }
                failed.remove(id)
            }
        }
        let next = RosterPayProfileCache(key: key, profiles: profiles, failedIds: failed, scope: scope)
        return (FirebaseBackend.layingRosterPayProfiles(raw, profiles: profiles), next, failed)
    }

    /// The roster's state after an answer: failed when nobody's pay could be read (an all-or-nothing `.all` read that
    /// failed), never ready; otherwise ready, with the failed people blocked one by one.
    static func rosterPayLoadAfterResult(_ raw: [AppUser], failedIds: Set<String>) -> PayOverlayLoad {
        guard !raw.isEmpty else { return .ready }
        return raw.allSatisfy({ failedIds.contains($0.id.lowercased()) }) ? .failed : .ready
    }

    /// The roster rows as the users documents hold them: a row still showing pay this store laid over (`laid`: per id,
    /// the pay the document held and the pay shown) gets the document's pay back, so pay is always laid over the raw
    /// rows and a deleted or unreadable profile never keeps old values. A row whose pay changed since (a new snapshot,
    /// an edit) is the document's own.
    static func rosterRawRows(
        _ users: [AppUser],
        laid: [String: (raw: RosterPayFields, shown: RosterPayFields)]
    ) -> [AppUser] {
        guard !laid.isEmpty else { return users }
        return users.map { user in
            guard let entry = laid[user.id], RosterPayFields(user) == entry.shown else { return user }
            return entry.raw.applied(to: user)
        }
    }

    /// The pay laid over each row: raw → shown, for the rows whose pay the overlay changed.
    static func rosterPayLaidMap(raw: [AppUser], shown: [AppUser]) -> [String: (raw: RosterPayFields, shown: RosterPayFields)] {
        var byId: [String: AppUser] = [:]
        for user in raw { byId[user.id] = user }
        var out: [String: (raw: RosterPayFields, shown: RosterPayFields)] = [:]
        for user in shown {
            guard let before = byId[user.id] else { continue }
            let rawFields = RosterPayFields(before)
            let shownFields = RosterPayFields(user)
            if rawFields != shownFields { out[user.id] = (rawFields, shownFields) }
        }
        return out
    }

    /// The organisation the own read belongs to (tests may set `ownPayOrganizationIdOverride`).
    var ownPayOrganizationId: String {
        (ownPayOrganizationIdOverride ?? firebaseBackend?.currentOrganization?.firestoreDocumentId ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ownPayCurrentKey: String {
        Self.ownPayKey(user: currentUser, organizationId: ownPayOrganizationId)
    }

    /// RULEBOOK §8: the signed-in person's own record with their pay profile laid over (while `privatePay` is on). Use
    /// this — or `displayUser`, which is built from it — wherever the person's own employment type or rates are read.
    var currentUserWithPay: AppUser? {
        guard let user = currentUser else { return nil }
        return Self.layingOwnPay(ownPayOverlay, over: user, key: ownPayCurrentKey, privatePay: SecuritySwitchContext.privatePay)
    }

    /// True when the person's own employment type can be decided on: nobody is signed in, or `platformConfig/app` has
    /// answered and either `privatePay` is off or the own record is decidable (`ownPayDecidable`). My Timesheets and the
    /// timesheet reminder wait while this is false — never deciding on a stripped document.
    var ownPayReady: Bool {
        guard currentUser != nil else { return true }
        guard SecuritySwitchContext.hasRead else { return false }
        guard SecuritySwitchContext.privatePay else { return true }
        return Self.ownPayDecidable(ownPayOverlay, key: ownPayCurrentKey)
    }

    /// True when the own read finished without an answer and no good record is held (the hub says so).
    var ownPayLoadFailed: Bool {
        guard currentUser != nil, SecuritySwitchContext.hasRead, SecuritySwitchContext.privatePay else { return false }
        return Self.ownPayLoad(ownPayOverlay, key: ownPayCurrentKey) == .failed
    }

    /// True when the person's own pay is confirmed by a finished read (the server, or this phone's copy while offline):
    /// the launch cache copy alone is not enough. The timesheet reminder writes and removes inbox rows only then.
    var ownPaySettled: Bool {
        guard currentUser != nil else { return true }
        guard SecuritySwitchContext.hasRead else { return false }
        guard SecuritySwitchContext.privatePay else { return true }
        return Self.ownPayLoad(ownPayOverlay, key: ownPayCurrentKey) == .ready
    }

    /// Reads the signed-in person's pay profile again when the key changed (or `force`). Nothing is read while
    /// `privatePay` is off or not yet known.
    func scheduleOwnPayOverlay(force: Bool = false, attempt: Int = 0) {
        let orgId = ownPayOrganizationId
        let key = Self.ownPayKey(user: currentUser, organizationId: orgId)
        let reader: PayProfileReading? = payProfileReaderOverride ?? firebaseBackend.map { $0 as PayProfileReading }
        guard SecuritySwitchContext.privatePay, let user = currentUser, let reader, !orgId.isEmpty else {
            ownPayOverlayGeneration &+= 1
            if ownPayOverlay != OwnPayOverlayState() { ownPayOverlay = OwnPayOverlayState() }
            publishPayOverlayReadiness()
            return
        }
        guard force || ownPayOverlay.key != key else { return }
        ownPayOverlayGeneration &+= 1
        let generation = ownPayOverlayGeneration
        // Keep the previous record while the same person is read again (no flicker); a new key starts empty.
        let previous = ownPayOverlay.key == key ? ownPayOverlay : OwnPayOverlayState()
        ownPayOverlay = OwnPayOverlayState(
            key: key,
            finished: false,
            readable: true,
            record: previous.record,
            recordConfirmed: previous.recordConfirmed
        )
        publishPayOverlayReadiness()
        Task { @MainActor [weak self] in
            // Launch: show the last good copy this phone holds while the server answers (display decisions only;
            // signing waits for the server, and a refusal drops it).
            if previous.record == nil,
               let cached = await reader.cachedPayProfile(organizationId: orgId, subjectId: user.id) {
                guard let self, generation == self.ownPayOverlayGeneration, !self.ownPayOverlay.finished else { return }
                self.ownPayOverlay.record = user.payShown(with: cached, profileId: user.id, privatePay: true)
                self.ownPayOverlay.recordConfirmed = false
                self.publishPayOverlayReadiness()
            }
            var reads: [(id: String, read: Bool, data: [String: Any]?)] = []
            var ownOffline = false
            var ownFromCache = false
            for id in [user.id] + user.formerUserIds {
                // Own id: the server, else this phone's copy only when offline. Former ids: the server only.
                let answer = await reader.readPayProfile(
                    organizationId: orgId,
                    subjectId: id,
                    cacheWhenOffline: id == user.id
                )
                if id == user.id {
                    ownOffline = answer.offline
                    ownFromCache = answer.read && answer.offline
                }
                reads.append((id: id, read: answer.read, data: answer.data))
                if answer.data != nil { break }
            }
            guard let self, generation == self.ownPayOverlayGeneration else { return }
            let result = Self.ownPayRecord(user: user, reads: reads)
            if !result.readable {
                NSLog("PAY_PROFILE_OWN_READ_FAILED org=%@ offline=%@ attempt=%ld", orgId, ownOffline ? "yes" : "no", attempt)
            }
            self.ownPayOverlay = Self.ownPayStateAfterRead(
                key: key,
                previous: self.ownPayOverlay,
                record: result.record,
                readable: result.readable,
                offline: ownOffline,
                fromCache: ownFromCache
            )
            self.publishPayOverlayReadiness()
            // Not read, or only from this phone's copy: try again a few times; the next foreground or the phone coming
            // back online tries again too.
            if !result.readable || ownFromCache, attempt < 3 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UserStore.payOverlayRetryDelayNanoseconds)
                    guard let self, generation == self.ownPayOverlayGeneration,
                          !self.ownPayOverlay.readable || self.ownPayOverlay.answeredFromCache else { return }
                    self.scheduleOwnPayOverlay(force: true, attempt: attempt + 1)
                }
            }
            // The timesheet reminder waited for the person's employment type (RULEBOOK §13 `timesheetParticipant`); it
            // still waits (and writes nothing) while the record is not decidable.
            await self.notificationService?.refreshTimesheetSubmissionReminders()
        }
    }

    /// The app came back to the foreground (or online): a failed own read, or one answered only from this phone's
    /// cache, is tried again.
    func retryOwnPayOverlayIfFailed() {
        guard SecuritySwitchContext.privatePay, ownPayOverlay.finished,
              !ownPayOverlay.readable || ownPayOverlay.answeredFromCache else { return }
        scheduleOwnPayOverlay(force: true)
    }

    /// `platformConfig/app` answered for the first time: the decisions held until then run now. When the first answer
    /// also changed the switches, `securitySwitchesDidChange` starts the overlays, so they start once (review of #240).
    func securitySwitchesFirstRead(switchesChanged: Bool) {
        if !switchesChanged {
            scheduleOwnPayOverlay(force: true)
            schedulePrivatePayOverlay()
        }
        publishPayOverlayReadiness()
        objectWillChange.send()
        // With `privatePay` on the own read refreshes the reminder when it finishes.
        if !SecuritySwitchContext.privatePay {
            Task { await self.notificationService?.refreshTimesheetSubmissionReminders() }
        }
    }

    func publishPayOverlayReadiness() {
        let own: PayOverlayLoad = currentUser == nil || !SecuritySwitchContext.privatePay
            ? .ready
            : Self.ownPayLoad(ownPayOverlay, key: ownPayCurrentKey)
        let roster: PayOverlayLoad = SecuritySwitchContext.privatePay ? rosterPayOverlayLoad : .ready
        let failed: Set<String> = SecuritySwitchContext.privatePay ? rosterPayFailedIds : []
        let names = organizationUsers
            .filter { failed.contains($0.id.lowercased()) }
            .map { $0.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0.email : $0.fullName }
            .sorted()
        let fromCache = SecuritySwitchContext.privatePay && rosterPayFromCache
        guard own != PrivatePayOverlayReadiness.own
            || roster != PrivatePayOverlayReadiness.roster
            || failed != PrivatePayOverlayReadiness.failedPersonIds
            || names != PrivatePayOverlayReadiness.failedPersonNames
            || fromCache != PrivatePayOverlayReadiness.rosterFromCache else { return }
        PrivatePayOverlayReadiness.update(
            own: own, roster: roster, failedPersonIds: failed, failedPersonNames: names, rosterFromCache: fromCache
        )
        bumpPayOverlayVersion()
        // Pay screens compute their block message in `body`: redraw them when it changes.
        objectWillChange.send()
    }
}

/// One pay-profile read: whether it answered, the data, and whether it failed because the phone is offline.
struct PayProfileRead {
    var read: Bool
    var data: [String: Any]?
    var offline: Bool
}

extension FirebaseBackend: PayProfileReading {
    /// Reads `payProfiles/{subjectId}` of `organizationId` (captured when the read began, never the open organisation
    /// later). From the server; only when that fails because the phone is offline, and `cacheWhenOffline`, from this
    /// phone's copy. A refusal is never answered from the cache. `read` false when nothing answered (never "no profile").
    func readPayProfile(organizationId: String, subjectId: String, cacheWhenOffline: Bool) async -> PayProfileRead {
        guard let path = CanonicalBusinessEngine.payProfilePath(organizationId: organizationId, subjectId: subjectId) else {
            return PayProfileRead(read: false, data: nil, offline: false)
        }
        do {
            let snap = try await db.document(path).getDocument(source: .server)
            guard snap.exists, let data = snap.data() else { return PayProfileRead(read: true, data: nil, offline: false) }
            return PayProfileRead(read: true, data: FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? data, offline: false)
        } catch {
            let ns = error as NSError
            let offline = Self.payProfileReadErrorIsOffline(domain: ns.domain, code: ns.code)
            guard offline, cacheWhenOffline,
                  let snap = try? await db.document(path).getDocument(source: .cache) else {
                return PayProfileRead(read: false, data: nil, offline: offline)
            }
            guard snap.exists, let data = snap.data() else { return PayProfileRead(read: true, data: nil, offline: true) }
            return PayProfileRead(read: true, data: FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? data, offline: true)
        }
    }

    /// This phone's cached copy of `payProfiles/{subjectId}`, or nil (launch display only, `scheduleOwnPayOverlay`).
    func cachedPayProfile(organizationId: String, subjectId: String) async -> [String: Any]? {
        guard let path = CanonicalBusinessEngine.payProfilePath(organizationId: organizationId, subjectId: subjectId),
              let snap = try? await db.document(path).getDocument(source: .cache),
              snap.exists, let data = snap.data() else { return nil }
        return FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? data
    }

    /// Whether a failed read failed because the phone is offline (Firestore unavailable or deadline exceeded, or a
    /// network error) — never a refusal (permission denied, code 7).
    nonisolated static func payProfileReadErrorIsOffline(domain: String, code: Int) -> Bool {
        if domain == NSURLErrorDomain { return true }
        if domain == "FIRFirestoreErrorDomain" { return code == 4 || code == 14 }
        return false
    }
}
