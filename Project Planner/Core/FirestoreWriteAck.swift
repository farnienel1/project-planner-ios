//
//  FirestoreWriteAck.swift
//  Project Planner
//
//  1.33.1: a Firestore `setData` / `updateData` awaited with async/await returns only when the server confirms the
//  write. Firestore has already applied it to its local cache and keeps it in its own write queue, so when the
//  confirmation is slow or never comes (a weak signal the phone still reports as online), the caller's spinner waited
//  for ever although the booking was there. This waits for the confirmation for a bounded time, then throws `TimedOut`.
//
//  A timed-out write is NOT copied into the app's offline outbox: Firestore's own queue already holds it, delivers it
//  in order (later writes to the same document go after it), and keeps it across an app kill (the SDK's persistent
//  cache is on by default on Apple platforms; this app sets no `FirestoreSettings`, see `FirebaseBackend.db`). Copying
//  it into the outbox as well sent it twice and needed a chain of extra rules. The caller reports it as "Pending sync";
//  `SDKPendingWrites` remembers which documents still wait for the server and forgets them when the write lands.
//

import Combine
import Foundation
@preconcurrency import FirebaseFirestore

enum FirestoreWriteAck {
    /// How long a booking save waits for the server's confirmation before it is reported as Pending sync.
    static let defaultTimeoutSeconds: Double = 15

    /// The server did not confirm in time. Firestore still holds the write and sends it: the caller reports Pending
    /// sync and never queues it again in the app outbox. The wording avoids "network" / "offline" on purpose, so
    /// `OfflineWriteSupport.shouldQueue` never reads it as a reason to queue a second copy.
    nonisolated struct TimedOut: LocalizedError, Equatable {
        var errorDescription: String? {
            "Saved on this phone. Pending sync — the server has not confirmed it yet."
        }
    }

    /// A server read made before an edit did not answer in time. Nothing was written. The edit then goes on without
    /// the server check (`FirebaseBackend.readBeforeEdit`).
    nonisolated struct ReadTimedOut: LocalizedError, Equatable {
        var errorDescription: String? {
            "The server did not answer in time."
        }
    }

    /// True when `error` is the bounded wait on a write Firestore already holds: report Pending sync, write nothing more.
    nonisolated static func isPendingInSDK(_ error: Error) -> Bool {
        error is TimedOut
    }

    /// How an edit checks that the booking still exists before writing.
    nonisolated enum EditReadSource: Equatable {
        /// `getDocument(source: .server)` (bounded): the normal case.
        case server
        /// The local cache: this device has a write to the document Firestore has not delivered yet (for example a
        /// create whose confirmation timed out). The server cannot have it yet; Firestore writes the edit after it.
        case localCache
    }

    /// `afterTimeout` (1.33.1 review item 1): once one wait of this save timed out, the server read is skipped and the
    /// cache is read, so a Confirm on a dead link does not wait again for a read that cannot answer.
    nonisolated static func editReadSource(pendingOnThisDevice: Bool, afterTimeout: Bool = false) -> EditReadSource {
        (pendingOnThisDevice || afterTimeout) ? .localCache : .server
    }

    /// What an edit does with what its read found.
    nonisolated enum EditReadOutcome: Equatable {
        /// The stored copy is known: write only what differs from it (`bookingUpdateWriteFields`).
        case diffAgainstStored
        /// The server answered that the document does not exist: refused, never re-created
        /// (`editOfMissingDocumentIsRefused`, `bookingReplayRefusedIsFinal`).
        case refuseMissing
        /// Nothing reliable was read (the server read timed out, or the cache does not have it): write the edited
        /// fields with `updateData`, which Firestore queues and the server refuses if the document is really gone.
        case writeUnchecked
    }

    nonisolated static func editReadOutcome(answeredByServer: Bool, exists: Bool) -> EditReadOutcome {
        if exists { return .diffAgainstStored }
        return answeredByServer ? .refuseMissing : .writeUnchecked
    }

    /// Runs `write` and returns when it finishes or after `seconds`, whichever comes first (then throws
    /// `timeoutError`, `TimedOut` by default). The write is never cancelled: Firestore keeps it and sends it when it can.
    /// With `pendingKey` (the document path), a write that times out is remembered in `SDKPendingWrites` until it
    /// finishes; a write the server later refuses is logged, never sent again. `onSettledAfterTimeout` is called once
    /// with that write's late outcome (nil: confirmed) when, and only when, its wait timed out first (with `TimedOut`),
    /// with or without `pendingKey` (#210 review: a My list save has no booking path to mark but must hear it too).
    @MainActor
    static func run(
        timeoutSeconds seconds: Double = defaultTimeoutSeconds,
        timeoutError: Error = TimedOut(),
        pendingKey: String? = nil,
        onSettledAfterTimeout: (@MainActor (Error?) -> Void)? = nil,
        _ write: @escaping () async throws -> Void
    ) async throws {
        let gate = ResumeOnce()
        let token = PendingToken()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.continuation = continuation
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                // Cancelled: the write finished first (review NIT), nothing to do.
                guard !Task.isCancelled else { return }
                if gate.resume(with: .failure(timeoutError)), timeoutError is TimedOut {
                    token.timedOut = true
                    if let pendingKey {
                        token.marked = true
                        SDKPendingWrites.shared.mark(pendingKey)
                    }
                }
            }
            Task { @MainActor in
                var failure: Error?
                do {
                    try await write()
                } catch {
                    failure = error
                }
                // The write finished: its timer has nothing left to do (review NIT).
                timer.cancel()
                // 1.33.1 review fix 1: the caller hears this write's own late outcome first (a refused delete puts
                // its booking's queued edit back), then the stores hear of a refusal.
                if token.timedOut {
                    onSettledAfterTimeout?(failure)
                }
                if let pendingKey, token.marked {
                    SDKPendingWrites.shared.settle(pendingKey, error: failure)
                }
                if let failure {
                    gate.resume(with: .failure(failure))
                } else {
                    gate.resume(with: .success(()))
                }
            }
        }
    }

    /// Whether this write's timeout marked it pending (so its late finish clears exactly that mark).
    @MainActor
    private final class PendingToken {
        /// The wait timed out with `TimedOut` (the late outcome goes to `onSettledAfterTimeout`).
        var timedOut = false
        var marked = false
    }

    /// Resumes the continuation once; the later of the write and the timer is ignored.
    private nonisolated final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CheckedContinuation<Void, Error>?

        var continuation: CheckedContinuation<Void, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }

        /// True when this call resumed the continuation (it was the first).
        @discardableResult
        func resume(with result: Result<Void, Error>) -> Bool {
            lock.lock()
            let pending = stored
            stored = nil
            lock.unlock()
            guard let pending else { return false }
            pending.resume(with: result)
            return true
        }
    }
}

/// Documents with a write Firestore holds but the server has not confirmed (its bounded wait timed out). In memory
/// only: after an app kill Firestore still delivers the write, and the live listener shows the booking from its cache.
/// Used for "Pending sync" on screen and so an edit or delete of such a booking is written through Firestore after it
/// (never refused as not-found, never queued in the app outbox as a second copy).
@MainActor
final class SDKPendingWrites: ObservableObject {
    static let shared = SDKPendingWrites()

    /// Lower-cased document path → number of timed-out writes still on their way. Published so a row's "Pending sync"
    /// (`PendingSyncIndicator`) appears and goes with it (1.33.1 review item 3).
    @Published private var counts: [String: Int] = [:]

    /// A booking write the server refused after its wait had timed out (1.33.1 review item 4). `userInfo`:
    /// `organizationId`, `collection`, `documentId` (as written in the path). The stores drop their local copy so the
    /// next listener snapshot is the truth.
    static let lateRefusalNotification = Notification.Name("SDKPendingWrites.lateRefusal")

    /// The parts of a booking document path (`organizations/{orgId}/{collection}/{documentId}`), nil for any other path.
    nonisolated static func pathParts(_ path: String) -> (organizationId: String, collection: String, documentId: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4, parts[0].lowercased() == "organizations",
              !parts[1].isEmpty, !parts[2].isEmpty, !parts[3].isEmpty else { return nil }
        return (parts[1], parts[2], parts[3])
    }

    /// The document path, lower-cased (ids compare without case, RULEBOOK §1).
    nonisolated static func key(organizationId: String, collection: String, documentId: String) -> String {
        "organizations/\(organizationId)/\(collection)/\(documentId)".lowercased()
    }

    func mark(_ path: String) {
        counts[path.lowercased(), default: 0] += 1
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }

    /// The write finished after its wait timed out. Refused by the server: never sent again. 1.33.1 review item 4: the
    /// person is told (`lateRefusalMessage`, the app-wide "Change not saved" alert) and the stores drop the
    /// local optimistic copy, so the live listener's next snapshot (Firestore rolled the write back) is what shows.
    func settle(_ path: String, error: Error?) {
        let key = path.lowercased()
        if let count = counts[key] {
            if count <= 1 { counts.removeValue(forKey: key) } else { counts[key] = count - 1 }
        }
        if let error {
            print("🔥🔥🔥 DEBUG: [SDKPendingWrites] Write to \(path) was refused after its wait timed out (not resent): \(error.localizedDescription)")
            Self.reportLateRefusal(path: path)
        }
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }

    /// 1.33.1 review NIT 4: what the person is told when a write Firestore held (a create, an edit or a delete whose
    /// wait timed out) is refused later. Not `BOOKING_REPLAY_REFUSED_MESSAGE` ("cancelled or deleted on another
    /// device"), which stays for real outbox replay refusals: a late refusal is usually a permission or a rule, not
    /// another device. (Owner choice pending; this is the recommended wording.)
    static let lateRefusalMessage = "This change couldn't be saved. Please check the booking and try again."

    /// Tells the person and the stores that a write Firestore held was refused by the server.
    static func reportLateRefusal(path: String) {
        OfflineOutboxStore.shared.lastRefusalMessage = lateRefusalMessage
        guard let parts = pathParts(path) else { return }
        NotificationCenter.default.post(
            name: lateRefusalNotification,
            object: nil,
            userInfo: ["organizationId": parts.organizationId, "collection": parts.collection, "documentId": parts.documentId]
        )
    }

    func contains(path: String) -> Bool {
        (counts[path.lowercased()] ?? 0) > 0
    }

    /// Any organisation: a booking id is unique (screens only show the open organisation's bookings).
    func contains(collection: String, documentId: String) -> Bool {
        let suffix = "/\(collection)/\(documentId)".lowercased()
        return counts.contains { $0.value > 0 && $0.key.hasSuffix(suffix) }
    }

    /// Tests only.
    func removeAll() {
        counts.removeAll()
    }
}

/// 1.33.1 review item 1: one save — a Schedule booking Confirm (its edits and new bookings) or one Edit booking Save —
/// shares one organisation (resolved once, never per booking) and one "a wait timed out" state. Before, each booking
/// paid its own organisation read (up to 8 s), its own read before an edit (15 s) and its own confirmation wait (15 s),
/// about 38 s per booking on a dead link. After the first timeout every later wait of the save is
/// `afterTimeoutWaitSeconds` at most and the read before an edit goes to this device's cache; a save that has run for
/// `budgetSeconds` waits no longer than that either. What is written, and in what order, is unchanged: a write that is
/// not confirmed in time stays with Firestore and is reported Pending sync.
@MainActor
final class BookingWriteSession {
    /// The longest any wait of a save lasts once one wait of it has timed out.
    static let afterTimeoutWaitSeconds: Double = 1
    /// The organisation check's server read (as `getDocumentWithServerTimeoutAndCacheFallback`).
    static let organizationReadSeconds: Double = 8
    /// After this long, a save's later waits are short as if one had timed out.
    static let budgetSeconds: Double = 20

    /// The organisation captured when Save was pressed.
    let organizationId: String?
    private(set) var timedOut = false
    private let startedAt: Date
    private let now: () -> Date
    /// Normalised preferred id → the id the check resolved.
    private var resolvedOrganizations: [String: String] = [:]

    init(organizationId: String?, now: @escaping () -> Date = { Date() }) {
        self.organizationId = organizationId
        self.now = now
        self.startedAt = now()
    }

    /// How long a wait of `full` seconds may last now.
    func wait(_ full: Double) -> Double {
        if timedOut { return min(full, Self.afterTimeoutWaitSeconds) }
        let remaining = Self.budgetSeconds - now().timeIntervalSince(startedAt)
        return min(full, max(Self.afterTimeoutWaitSeconds, remaining))
    }

    /// The confirmation wait of the next write.
    var ackSeconds: Double { wait(FirestoreWriteAck.defaultTimeoutSeconds) }
    /// The server read before the next edit.
    var editReadSeconds: Double { wait(FirestoreWriteAck.defaultTimeoutSeconds) }
    /// The organisation check, when it has not run yet.
    var organizationCheckSeconds: Double { wait(Self.organizationReadSeconds) }

    func noteTimeout() {
        timedOut = true
    }

    /// Notes a timed-out write or read of this save.
    func note(_ error: Error) {
        if error is FirestoreWriteAck.TimedOut || error is FirestoreWriteAck.ReadTimedOut { noteTimeout() }
    }

    /// The organisation every write of this save goes to, checked once. `check` gets its time limit and returns the
    /// id and whether the check timed out (then the rest of the save waits briefly).
    func organization(
        _ preferred: String,
        check: (_ timeoutSeconds: Double) async throws -> (id: String, timedOut: Bool)
    ) async throws -> String {
        let key = normalizedOrganizationId(preferred).lowercased()
        if let resolved = resolvedOrganizations[key] { return resolved }
        let result = try await check(organizationCheckSeconds)
        if result.timedOut { noteTimeout() }
        resolvedOrganizations[key] = result.id
        return result.id
    }
}
