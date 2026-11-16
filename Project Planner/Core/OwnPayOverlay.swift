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

/// Whose pay a screen prices: the viewer's own (My Timesheets) or other people's (User Timesheets, the review, Export,
/// the weekly report). Each waits only for the overlay it needs.
enum PayOverlayScope: Equatable {
    case ownPay
    case othersPay
}

/// What one roster overlay read: the roster laid over, the profiles by document id, and whether any read failed.
struct RosterPayOverlayResult {
    var users: [AppUser]
    var profiles: [String: [String: Any]]
    var failed: Bool
}

/// The last good roster overlay (`UserStore.rosterPaySubjectsKey`: organisation, viewer and the people's ids).
struct RosterPayProfileCache {
    var key: String
    var profiles: [String: [String: Any]]
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
}

/// Whether the private-pay overlays are ready. Pay screens wait for it through `PayInputsLoad.blockMessage`. Set only by
/// `UserStore`; `platformConfig/app` not read yet always waits.
@MainActor
enum PrivatePayOverlayReadiness {
    static let loadingMessage = "Loading pay details…"
    static let ownFailedMessage = "Your pay details could not be loaded, so pay cannot be worked out. Check your connection and try again."
    static let rosterFailedMessage = "Pay details for the team could not be loaded, so pay cannot be worked out. Check your connection and try again."

    private(set) static var own: PayOverlayLoad = .ready
    private(set) static var roster: PayOverlayLoad = .ready

    static func update(own: PayOverlayLoad, roster: PayOverlayLoad) {
        self.own = own
        self.roster = roster
    }

    /// Back to "nothing pending" (tests, sign-out).
    static func reset() {
        update(own: .ready, roster: .ready)
    }

    /// Why pay cannot be worked out yet for `scope`, else nil. Before `platformConfig/app` has answered nothing is
    /// priced (the switch could be on). While `privatePay` is off nothing is read, so nothing is waited for.
    static func blockMessage(
        scope: PayOverlayScope,
        switchesKnown: Bool,
        privatePay: Bool,
        own: PayOverlayLoad,
        roster: PayOverlayLoad
    ) -> String? {
        guard switchesKnown else { return loadingMessage }
        guard privatePay else { return nil }
        switch scope == .ownPay ? own : roster {
        case .ready: return nil
        case .loading: return loadingMessage
        case .failed: return scope == .ownPay ? ownFailedMessage : rosterFailedMessage
        }
    }

    static func blockMessage(scope: PayOverlayScope) -> String? {
        blockMessage(
            scope: scope,
            switchesKnown: SecuritySwitchContext.hasRead,
            privatePay: SecuritySwitchContext.privatePay,
            own: own,
            roster: roster
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
        offline: Bool
    ) -> OwnPayOverlayState {
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
        return state.record != nil || (state.finished && state.readable)
    }

    /// Whether the person's own pay may be priced and signed for `key` (`PrivatePayOverlayReadiness`, scope `.ownPay`):
    /// only from a finished read, or a confirmed record kept while the same person is read again or after a failure.
    static func ownPayLoad(_ state: OwnPayOverlayState, key: String) -> PayOverlayLoad {
        guard state.key == key else { return .loading }
        let confirmed = state.record != nil && state.recordConfirmed
        guard state.finished else { return confirmed ? .ready : .loading }
        if state.readable || confirmed { return .ready }
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
    static func rosterPaySubjectsKey(_ users: [AppUser], organizationId: String, viewerId: String?) -> String {
        let people = users
            .map { ([$0.id] + $0.formerUserIds).map { $0.lowercased() }.sorted().joined(separator: ",") }
            .sorted()
            .joined(separator: ";")
        return [organizationId, viewerId?.lowercased() ?? "", people].joined(separator: "|")
    }

    /// A new roster snapshot: with a good overlay of the same people, laid over from it at once and ready; otherwise as
    /// given and loading until its overlay answers.
    static func rosterPayAfterSnapshot(
        _ users: [AppUser],
        cache: RosterPayProfileCache?,
        key: String
    ) -> (users: [AppUser], load: PayOverlayLoad) {
        guard let cache, cache.key == key else { return (users, .loading) }
        return (FirebaseBackend.layingRosterPayProfiles(users, profiles: cache.profiles), .ready)
    }

    /// A failed roster overlay: still ready when a good overlay of the same people is laid over; otherwise failed.
    static func rosterPayLoadAfterFailure(cache: RosterPayProfileCache?, key: String) -> PayOverlayLoad {
        cache?.key == key ? .ready : .failed
    }

    private var ownPayCurrentKey: String {
        Self.ownPayKey(user: currentUser, organizationId: firebaseBackend?.currentOrganization?.firestoreDocumentId)
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

    /// Reads the signed-in person's pay profile again when the key changed (or `force`). Nothing is read while
    /// `privatePay` is off or not yet known.
    func scheduleOwnPayOverlay(force: Bool = false, attempt: Int = 0) {
        let orgId = firebaseBackend?.currentOrganization?.firestoreDocumentId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = Self.ownPayKey(user: currentUser, organizationId: orgId)
        guard SecuritySwitchContext.privatePay, let user = currentUser, let firebaseBackend, !orgId.isEmpty else {
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
               let cached = await firebaseBackend.cachedPayProfile(organizationId: orgId, subjectId: user.id) {
                guard let self, generation == self.ownPayOverlayGeneration, !self.ownPayOverlay.finished else { return }
                self.ownPayOverlay.record = user.payShown(with: cached, profileId: user.id, privatePay: true)
                self.ownPayOverlay.recordConfirmed = false
                self.publishPayOverlayReadiness()
            }
            var reads: [(id: String, read: Bool, data: [String: Any]?)] = []
            var ownOffline = false
            for id in [user.id] + user.formerUserIds {
                // Own id: the server, else this phone's copy only when offline. Former ids: the server only.
                let answer = await firebaseBackend.readPayProfile(
                    organizationId: orgId,
                    subjectId: id,
                    cacheWhenOffline: id == user.id
                )
                if id == user.id { ownOffline = answer.offline }
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
                offline: ownOffline
            )
            self.publishPayOverlayReadiness()
            // Not read: try again a few times; the next foreground tries again too.
            if !result.readable, attempt < 3 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self, generation == self.ownPayOverlayGeneration, !self.ownPayOverlay.readable else { return }
                    self.scheduleOwnPayOverlay(force: true, attempt: attempt + 1)
                }
            }
            // The timesheet reminder waited for the person's employment type (RULEBOOK §13 `timesheetParticipant`); it
            // still waits (and writes nothing) while the record is not decidable.
            await self.notificationService?.refreshTimesheetSubmissionReminders()
        }
    }

    /// The app came back to the foreground: a failed own read is tried again.
    func retryOwnPayOverlayIfFailed() {
        guard SecuritySwitchContext.privatePay, ownPayOverlay.finished, !ownPayOverlay.readable else { return }
        scheduleOwnPayOverlay(force: true)
    }

    /// `platformConfig/app` answered for the first time: the decisions held until then run now.
    func securitySwitchesFirstRead() {
        scheduleOwnPayOverlay(force: true)
        schedulePrivatePayOverlay()
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
        guard own != PrivatePayOverlayReadiness.own || roster != PrivatePayOverlayReadiness.roster else { return }
        PrivatePayOverlayReadiness.update(own: own, roster: roster)
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

extension FirebaseBackend {
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
