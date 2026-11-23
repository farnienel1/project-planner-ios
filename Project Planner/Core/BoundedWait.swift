//
//  BoundedWait.swift
//  Project Planner
//
//  A save never sticks on "Saving…" (owner decision 17 Nov, web "A save never sticks on Saving…"; issue #16 on iOS):
//  a Storage upload or Firestore write that does not answer within a fixed time is given up on with a real message.
//
//  Unlike a task-group timeout, this returns as soon as the time is up even when the work ignores cancellation (a
//  Firestore write waits for the server and never checks for cancellation; a task group would wait for it). The work
//  is still cancelled, so a Storage upload that listens for cancellation (`uploadQualificationDocument`) stops.
//

import Foundation
#if canImport(FirebaseStorage)
import FirebaseStorage
#endif

enum BoundedWait {
    /// The work did not answer in time.
    nonisolated struct TimedOut: LocalizedError, Equatable {
        let seconds: Double
        var errorDescription: String? {
            "No answer from the server after \(Int(seconds.rounded())) seconds. Check your connection and try again."
        }
    }

    /// Resumes a continuation exactly once, whichever of the work and the timer finishes first.
    nonisolated private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    /// `operation`, or `TimedOut` after `seconds` (the work is cancelled then and its late answer ignored).
    static func run<T>(seconds: Double, _ operation: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = Once()
            let work = Task {
                do {
                    let value = try await operation()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.claim() {
                    work.cancel()
                    continuation.resume(throwing: TimedOut(seconds: seconds))
                }
            }
        }
    }
}

#if canImport(FirebaseStorage)
/// Holds a Storage upload so a cancelled save can stop it (`FirebaseBackend.uploadQualificationDocument`).
nonisolated final class QualificationUploadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var _task: StorageUploadTask?

    var task: StorageUploadTask? {
        get { lock.lock(); defer { lock.unlock() }; return _task }
        set {
            lock.lock()
            _task = newValue
            let stop = cancelled
            lock.unlock()
            if stop { newValue?.cancel() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = _task
        lock.unlock()
        current?.cancel()
    }
}
#endif
