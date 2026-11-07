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

enum FirestoreWriteAck {
    /// How long a booking save waits for the server's confirmation before the store treats it as pending sync.
    static let defaultTimeoutSeconds: Double = 15

    nonisolated struct TimedOut: LocalizedError, Equatable {
        var errorDescription: String? {
            "The network did not confirm this save in time. It is saved on this phone and will sync when the connection recovers."
        }
    }

    /// Runs `write` and returns when it finishes or after `seconds`, whichever comes first (then throws `TimedOut`).
    /// The write is never cancelled: Firestore keeps it and sends it when it can.
    @MainActor
    static func run(timeoutSeconds seconds: Double = defaultTimeoutSeconds, _ write: @escaping () async throws -> Void) async throws {
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
                gate.resume(with: .failure(TimedOut()))
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
