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

    nonisolated static func editReadSource(pendingOnThisDevice: Bool) -> EditReadSource {
        pendingOnThisDevice ? .localCache : .server
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
    /// finishes; a write the server later refuses is logged, never sent again.
    @MainActor
    static func run(
        timeoutSeconds seconds: Double = defaultTimeoutSeconds,
        timeoutError: Error = TimedOut(),
        pendingKey: String? = nil,
        _ write: @escaping () async throws -> Void
    ) async throws {
        let gate = ResumeOnce()
        let token = PendingToken()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.continuation = continuation
            Task { @MainActor in
                var failure: Error?
                do {
                    try await write()
                } catch {
                    failure = error
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
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if gate.resume(with: .failure(timeoutError)), let pendingKey, timeoutError is TimedOut {
                    token.marked = true
                    SDKPendingWrites.shared.mark(pendingKey)
                }
            }
        }
    }

    /// Whether this write's timeout marked it pending (so its late finish clears exactly that mark).
    @MainActor
    private final class PendingToken {
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
final class SDKPendingWrites {
    static let shared = SDKPendingWrites()

    /// Lower-cased document path → number of timed-out writes still on their way.
    private var counts: [String: Int] = [:]

    /// The document path, lower-cased (ids compare without case, RULEBOOK §1).
    nonisolated static func key(organizationId: String, collection: String, documentId: String) -> String {
        "organizations/\(organizationId)/\(collection)/\(documentId)".lowercased()
    }

    func mark(_ path: String) {
        counts[path.lowercased(), default: 0] += 1
        ScheduleChangeNotifier.postBookingStoreDidChange()
    }

    /// The write finished after its wait timed out. Refused by the server: logged, never sent again (the live listener
    /// drops the booking Firestore rolled back).
    func settle(_ path: String, error: Error?) {
        let key = path.lowercased()
        if let count = counts[key] {
            if count <= 1 { counts.removeValue(forKey: key) } else { counts[key] = count - 1 }
        }
        if let error {
            print("🔥🔥🔥 DEBUG: [SDKPendingWrites] Write to \(path) was refused after its wait timed out (not resent): \(error.localizedDescription)")
        }
        ScheduleChangeNotifier.postBookingStoreDidChange()
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
