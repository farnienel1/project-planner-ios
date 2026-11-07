//
//  FirestoreWriteAck.swift
//  Project Planner
//
//  1.33.1: a Firestore `setData` / `updateData` awaited with async/await returns only when the server confirms the
//  write. Firestore has already applied it to its local cache and keeps sending it, so when the confirmation is slow or
//  never comes (a weak signal the phone still reports as online), the caller's spinner waited for ever although the
//  booking was there. This waits for the confirmation for a bounded time, then throws `TimedOut`, whose message reads
//  as a network problem (`OfflineWriteSupport.shouldQueue`), so the store queues it as "Pending sync" exactly as it
//  does offline. Replaying a queued booking write is idempotent (same document id, same fields). Nothing about what is
//  written changes.
//

import Foundation
@preconcurrency import FirebaseFirestore

enum FirestoreWriteAck {
    /// How long a booking save waits for the server's confirmation before the store treats it as pending sync.
    static let defaultTimeoutSeconds: Double = 15

    nonisolated struct TimedOut: LocalizedError, Equatable {
        var errorDescription: String? {
            "The network did not confirm this save in time. It is saved on this phone and will sync when the connection recovers."
        }
    }

    /// A server read made before a write (an edit reads the stored booking first) did not answer in time. Nothing was
    /// handed to Firestore, so the change is queued as an ordinary offline edit (never sent, never a create). Reads as
    /// a network problem (`OfflineWriteSupport.shouldQueue`).
    nonisolated struct ReadTimedOut: LocalizedError, Equatable {
        var errorDescription: String? {
            "The network did not answer in time. The change is saved on this phone and will sync when the connection recovers."
        }
    }

    /// True when `error` is the bounded wait on a write Firestore already holds (`TimedOut`): the SDK keeps sending it,
    /// so the queued copy must be treated as possibly on the server already (`sentToServer`, 1.33.1 review item 1).
    /// A read timeout (`ReadTimedOut`) or any other error means nothing was handed over.
    nonisolated static func wasHandedToServer(_ error: Error) -> Bool {
        error is TimedOut
    }

    /// After a write timed out, further writes in this window are queued without waiting again (1.33.1 review item 2):
    /// 5 people × 5 days on a weak signal would otherwise wait 15 s each, one after another.
    nonisolated static let skipWaitWindowSeconds: Double = 30

    /// Whether a write now should go straight to the queue because a write timed out at `lastTimeout`.
    nonisolated static func skipsWait(lastTimeout: Date?, now: Date = Date()) -> Bool {
        guard let lastTimeout else { return false }
        let elapsed = now.timeIntervalSince(lastTimeout)
        return elapsed >= 0 && elapsed < skipWaitWindowSeconds
    }

    /// `Firestore.waitForPendingWrites`, bounded: returns once every write this device has handed to Firestore has been
    /// confirmed or refused by the server, else throws `TimedOut` after `seconds`. A queued delete of a booking whose
    /// create (or edit) was handed over waits for it first, so it never decides on a copy that is still on its way.
    @MainActor
    static func waitForPendingWrites(_ db: Firestore, timeoutSeconds seconds: Double = defaultTimeoutSeconds) async throws {
        try await run(timeoutSeconds: seconds) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                db.waitForPendingWrites { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Runs `write` and returns when it finishes or after `seconds`, whichever comes first (then throws
    /// `timeoutError`, `TimedOut` by default). The write is never cancelled: Firestore keeps it and sends it when it can.
    @MainActor
    static func run(
        timeoutSeconds seconds: Double = defaultTimeoutSeconds,
        timeoutError: Error = TimedOut(),
        _ write: @escaping () async throws -> Void
    ) async throws {
        let gate = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.continuation = continuation
            Task { @MainActor in
                do {
                    try await write()
                    gate.resume(with: .success(()))
                } catch {
                    gate.resume(with: .failure(error))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                gate.resume(with: .failure(timeoutError))
            }
        }
    }

    /// Resumes the continuation once; the later of the write and the timer is ignored.
    private nonisolated final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CheckedContinuation<Void, Error>?

        var continuation: CheckedContinuation<Void, Error>? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }

        func resume(with result: Result<Void, Error>) {
            lock.lock()
            let pending = stored
            stored = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }
}
