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
//  It also tells pay screens when the overlays have finished (`PrivatePayOverlayReadiness`), so nothing is signed,
//  counter-signed, invoiced, exported or reported on a stripped record. App plumbing only: every pay rule stays in the
//  packed script.
//

import Foundation
@preconcurrency import FirebaseFirestore

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
}

/// Whether the private-pay overlays (the signed-in person's own record and the roster) have finished. Pay screens wait
/// for it through `PayInputsLoad.blockMessage` while `privatePay` is on. Set only by `UserStore`.
@MainActor
enum PrivatePayOverlayReadiness {
    static let loadingMessage = "Loading pay details…"
    static let ownFailedMessage = "Your pay details could not be loaded, so pay cannot be worked out. Check your connection and try again."

    private(set) static var ownFinished = true
    private(set) static var ownReadable = true
    private(set) static var rosterFinished = true

    static func update(ownFinished: Bool, ownReadable: Bool, rosterFinished: Bool) {
        self.ownFinished = ownFinished
        self.ownReadable = ownReadable
        self.rosterFinished = rosterFinished
    }

    /// Back to "nothing pending" (tests, sign-out).
    static func reset() {
        update(ownFinished: true, ownReadable: true, rosterFinished: true)
    }

    /// Why pay cannot be worked out yet because a pay-profile overlay has not finished, else nil. Always nil while
    /// `privatePay` is off (nothing is read, so nothing is waited for).
    static func blockMessage(privatePay: Bool, ownFinished: Bool, ownReadable: Bool, rosterFinished: Bool) -> String? {
        guard privatePay else { return nil }
        guard ownFinished, rosterFinished else { return loadingMessage }
        return ownReadable ? nil : ownFailedMessage
    }

    static var blockMessage: String? {
        blockMessage(
            privatePay: SecuritySwitchContext.privatePay,
            ownFinished: ownFinished,
            ownReadable: ownReadable,
            rosterFinished: rosterFinished
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

    /// `user` with the own-pay record's pay fields, when the state belongs to this key and `privatePay` is on; else
    /// `user` unchanged. Only the six pay fields move (`withPayFields`); every other field stays as held. A record kept
    /// while the same person is read again stays laid over (no flicker back to the stripped document).
    static func layingOwnPay(_ state: OwnPayOverlayState, over user: AppUser, key: String, privatePay: Bool) -> AppUser {
        guard privatePay, state.key == key, let record = state.record, record.id == user.id else {
            return user
        }
        return user.withPayFields(of: record)
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

    /// True when the person's own pay can be read: `privatePay` is off, nobody is signed in, or the own read for the
    /// current key has answered. Screens that decide on the employment type wait while this is false.
    var ownPayReady: Bool {
        guard SecuritySwitchContext.privatePay, currentUser != nil else { return true }
        return ownPayOverlay.key == ownPayCurrentKey && ownPayOverlay.finished
    }

    /// Ids whose pay this phone has actually read from a pay profile: the roster rows laid over, and the signed-in
    /// person when their own profile was read. A row not listed while `privatePay` is on holds no readable pay (its
    /// stripped employment type reads as self-employed, so it must not decide "not PAYE").
    var payProfileReadIds: Set<String> {
        var ids = rosterPayOverlaidIds
        if ownPayReady, ownPayOverlay.record != nil, let id = currentUser?.id {
            ids.insert(id.lowercased())
        }
        return ids
    }

    /// Reads the signed-in person's pay profile again when the key changed (or `force`). Nothing is read while
    /// `privatePay` is off.
    func scheduleOwnPayOverlay(force: Bool = false, attempt: Int = 0) {
        let key = ownPayCurrentKey
        guard SecuritySwitchContext.privatePay, let user = currentUser, let firebaseBackend else {
            ownPayOverlayGeneration &+= 1
            if ownPayOverlay != OwnPayOverlayState() { ownPayOverlay = OwnPayOverlayState() }
            publishPayOverlayReadiness()
            return
        }
        guard force || ownPayOverlay.key != key else { return }
        ownPayOverlayGeneration &+= 1
        let generation = ownPayOverlayGeneration
        // Keep the previous record on screen while the same person is read again (no flicker); a new key starts empty.
        ownPayOverlay = OwnPayOverlayState(
            key: key,
            finished: false,
            readable: true,
            record: ownPayOverlay.key == key ? ownPayOverlay.record : nil
        )
        publishPayOverlayReadiness()
        Task { @MainActor [weak self] in
            var reads: [(id: String, read: Bool, data: [String: Any]?)] = []
            for id in [user.id] + user.formerUserIds {
                // Own id: server, else the cached copy. Former ids: the server only (a refused read is skipped).
                let answer: (read: Bool, data: [String: Any]?)
                if id == user.id {
                    answer = await firebaseBackend.readOwnPayProfile(subjectId: id)
                } else {
                    answer = await firebaseBackend.readPayProfileForLeave(subjectId: id)
                }
                reads.append((id: id, read: answer.read, data: answer.data))
                if answer.data != nil { break }
            }
            guard let self, generation == self.ownPayOverlayGeneration else { return }
            let result = Self.ownPayRecord(user: user, reads: reads)
            // A failed re-read keeps the record already read for this key.
            let record = result.record ?? (result.readable ? nil : self.ownPayOverlay.record)
            self.ownPayOverlay = OwnPayOverlayState(key: key, finished: true, readable: result.readable, record: record)
            self.publishPayOverlayReadiness()
            // Not read (offline, no cached copy): try again a few times; the next foreground tries again too.
            if !result.readable, attempt < 3 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard let self, generation == self.ownPayOverlayGeneration, !self.ownPayOverlay.readable else { return }
                    self.scheduleOwnPayOverlay(force: true, attempt: attempt + 1)
                }
            }
            // The timesheet reminder waited for the person's employment type (RULEBOOK §13 `timesheetParticipant`).
            await self.notificationService?.refreshTimesheetSubmissionReminders()
        }
    }

    /// The app came back to the foreground: a failed own read is tried again.
    func retryOwnPayOverlayIfFailed() {
        guard SecuritySwitchContext.privatePay, ownPayOverlay.finished, !ownPayOverlay.readable else { return }
        scheduleOwnPayOverlay(force: true)
    }

    func publishPayOverlayReadiness() {
        let on = SecuritySwitchContext.privatePay && currentUser != nil
        let ownCurrent = ownPayOverlay.key == ownPayCurrentKey
        let ownFinished = !on || (ownCurrent && ownPayOverlay.finished)
        // A failed re-read that kept the record already read still has the person's pay.
        let ownReadable = !on || !ownCurrent || ownPayOverlay.readable || ownPayOverlay.record != nil
        let rosterFinished = !SecuritySwitchContext.privatePay || !rosterPayOverlayPending
        guard ownFinished != PrivatePayOverlayReadiness.ownFinished
            || ownReadable != PrivatePayOverlayReadiness.ownReadable
            || rosterFinished != PrivatePayOverlayReadiness.rosterFinished else { return }
        PrivatePayOverlayReadiness.update(ownFinished: ownFinished, ownReadable: ownReadable, rosterFinished: rosterFinished)
        // Pay screens compute their block message in `body`: redraw them when it changes.
        objectWillChange.send()
    }
}

extension FirebaseBackend {
    /// Reads the signed-in person's own `payProfiles/{subjectId}`: the server first, then this phone's cached copy (so an
    /// offline phone still knows its own employment type). `read` false when neither answered (never "no profile").
    func readOwnPayProfile(subjectId: String) async -> (read: Bool, data: [String: Any]?) {
        let server = await readPayProfileForLeave(subjectId: subjectId)
        if server.read { return server }
        guard let orgId = currentOrganization?.firestoreDocumentId,
              let path = CanonicalBusinessEngine.payProfilePath(organizationId: orgId, subjectId: subjectId),
              let snap = try? await db.document(path).getDocument(source: .cache) else {
            return (false, nil)
        }
        guard snap.exists, let data = snap.data() else { return (true, nil) }
        return (true, FirebaseBackend.firestoreJSON(data) as? [String: Any] ?? data)
    }
}

extension OvertimeReopenNotice {
    /// Whether the reopen notice should go on to `overtimeLineReopened` for `person`. While `privatePay` is off: only a
    /// PAYE person (the users document holds the type). While it is on: a PAYE person, or anyone whose pay profile this
    /// phone did not read (`payProfileReadIds`, lower case) — their stripped document's "self-employed" is not an answer,
    /// so the rulebook decides from their overtime records instead.
    static func mayBePaye(_ person: AppUser, privatePay: Bool, payProfileReadIds: Set<String>) -> Bool {
        if person.isPayeEmployment { return true }
        guard privatePay else { return false }
        return !payProfileReadIds.contains(person.id.lowercased())
    }
}
